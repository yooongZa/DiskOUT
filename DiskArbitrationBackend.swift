//
//  DiskArbitrationBackend.swift
//  EjectDrives
//
//  diskutil/hdiutil 외부 명령 호출을 대체하는 DiskArbitration framework wrapper.
//  App Store sandbox 환경에서도 동작하도록 모든 디스크 작업을 framework API 로 처리.
//
//  사용 패턴: 모든 함수는 background thread 에서 동기 호출. DA 의 비동기 callback 은
//  DispatchSemaphore 로 wrapping. main thread 에서 직접 호출하면 deadlock 위험.
//

import Foundation
import DiskArbitration
import IOKit
import os

private let daLog = Logger(subsystem: "com.yongza.ejectdrives", category: "da")

/// DiskArbitration 작업 결과. runDiskutil 의 (success: Bool, errorMessage: String?) 와 호환.
struct DAResult {
    let success: Bool
    let errorMessage: String?

    static let ok = DAResult(success: true, errorMessage: nil)
    static func failure(_ message: String) -> DAResult { DAResult(success: false, errorMessage: message) }
}

/// DiskArbitration 세션 + 동기 작업 wrapper.
/// 인스턴스 1개를 앱 lifetime 동안 유지. background queue 에 callback 이 dispatch 됨.
final class DiskArbitrationBackend {

    static let shared = DiskArbitrationBackend()

    private let session: DASession
    private let queue: DispatchQueue

    private init() {
        guard let s = DASessionCreate(kCFAllocatorDefault) else {
            fatalError("DASessionCreate failed — DiskArbitration framework unavailable")
        }
        self.session = s
        self.queue = DispatchQueue(label: "com.yongza.ejectdrives.da", qos: .userInitiated)
        DASessionSetDispatchQueue(session, queue)
    }

    // MARK: - Disk creation

    /// volume mount path (예: `/Volumes/MyDrive`) 로부터 DADisk 생성.
    /// 마운트 안 된 디스크는 nil 반환.
    func disk(forVolumePath path: String) -> DADisk? {
        let url = URL(fileURLWithPath: path) as CFURL
        return DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url)
    }

    /// BSD name (예: `disk2`, `disk2s1`) 로부터 DADisk 생성.
    /// 디스크가 enumerate 되지 않으면 nil.
    func disk(forBSDName bsd: String) -> DADisk? {
        return bsd.withCString { cstr in
            DADiskCreateFromBSDName(kCFAllocatorDefault, session, cstr)
        }
    }

    // MARK: - Unmount (recursively whole disk)

    /// 디스크를 unmount. graceful 시도만 (force 옵션은 sandbox 에서 거절될 수 있어 사용 X).
    /// background thread 에서 동기 호출. 일반적 응답 시간 1~5초, 점유 시 거절.
    func unmount(disk: DADisk, timeout: TimeInterval = 30) -> DAResult {
        let semaphore = DispatchSemaphore(value: 0)
        // dissenter (거절 정보) 를 캡처해 호출자에게 돌려줌.
        // closure 가 C function 으로 캐스팅되므로 reference 를 통해 결과 전달.
        let box = ResultBox()
        let ctx = Unmanaged.passRetained(box).toOpaque()

        let options = DADiskUnmountOptions(kDADiskUnmountOptionWhole)

        DADiskUnmount(disk, options, { (_, dissenter, ctx) in
            guard let ctx = ctx else { return }
            let box = Unmanaged<ResultBox>.fromOpaque(ctx).takeRetainedValue()
            if let dissenter = dissenter {
                let status = DADissenterGetStatus(dissenter)
                let cfReason = DADissenterGetStatusString(dissenter)
                let reason = (cfReason as String?) ?? unixDescription(forStatus: status)
                box.result = .failure("unmount declined: \(reason)")
            } else {
                box.result = .ok
            }
            box.semaphore.signal()
        }, ctx)
        box.semaphore = semaphore

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            // semaphore 에 대한 callback 의 retain 은 이미 끝났을 수 있음 — 단순히 timeout 보고만.
            return .failure("unmount timeout (\(Int(timeout))s)")
        }
        return box.result ?? .failure("unknown")
    }

    // MARK: - Mount

    /// 디스크 마운트 — `/Volumes/<volumeName>` 자동 결정 (mountpoint=nil).
    func mount(disk: DADisk, timeout: TimeInterval = 30) -> DAResult {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        box.semaphore = semaphore
        let ctx = Unmanaged.passRetained(box).toOpaque()

        DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), { (_, dissenter, ctx) in
            guard let ctx = ctx else { return }
            let box = Unmanaged<ResultBox>.fromOpaque(ctx).takeRetainedValue()
            if let dissenter = dissenter {
                let status = DADissenterGetStatus(dissenter)
                let cfReason = DADissenterGetStatusString(dissenter)
                let reason = (cfReason as String?) ?? unixDescription(forStatus: status)
                box.result = .failure("mount declined: \(reason)")
            } else {
                box.result = .ok
            }
            box.semaphore.signal()
        }, ctx)

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return .failure("mount timeout (\(Int(timeout))s)")
        }
        return box.result ?? .failure("unknown")
    }

    // MARK: - Description

    /// 디스크 description dict — `kDADiskDescriptionVolumeNameKey`, `DeviceProtocolKey` 등 모든 metadata.
    /// disk 가 invalid 면 nil.
    func description(for disk: DADisk) -> [String: Any]? {
        guard let cf = DADiskCopyDescription(disk) else { return nil }
        return cf as? [String: Any]
    }

    /// 가상 디스크 (DMG, sparseimage, CoreSimulator 등) 인지 여부.
    /// `kDADiskDescriptionDeviceProtocolKey == "Disk Image"` 또는 `"Virtual Interface"` 매칭.
    /// hdiutil info 호출의 sandbox-호환 대체.
    func isVirtualDisk(_ disk: DADisk) -> Bool {
        guard let desc = description(for: disk) else { return false }
        return Self.virtualProtocols.contains(desc[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? "")
    }

    /// 외장(internal=false) whole disk 의 BSD name 들. virtual 도 포함 — 호출자가 필터.
    /// `diskutil list -plist external` 의 sandbox-호환 대체.
    func enumerateExternalWholeDisks() -> [String] {
        guard let matching = IOServiceMatching("IOMedia") else { return [] }
        let dict = matching as NSMutableDictionary
        dict["Whole"] = kCFBooleanTrue   // whole disk 만
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iter) }

        var result: [String] = []
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            guard let bsd = bsdName(of: svc) else { continue }
            // 내장 디스크 제외 — DA description 의 DeviceInternal 신뢰.
            guard let disk = self.disk(forBSDName: bsd),
                  let desc = description(for: disk)
            else { continue }
            let isInternal = desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? true
            guard !isInternal else { continue }
            result.append(bsd)
        }
        return result
    }

    /// 주어진 whole disk (예: "disk2") 의 child partition / APFS volume BSD 들 ("disk2s1" 등).
    /// `diskutil mountDisk <whole>` 가 mount 하는 대상들 — 우리는 각각 DADiskMount 호출.
    func childPartitions(ofWholeDisk wholeBSD: String) -> [String] {
        guard let matching = IOServiceMatching("IOMedia") else { return [] }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iter) }

        var result: [String] = []
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            guard let bsd = bsdName(of: svc) else { continue }
            // wholeBSD 의 child 인지 — "disk2" 의 자식은 "disk2s1", "disk2s2"... + APFS 는 별도 synth disk.
            // 단순 prefix 매칭 + whole 자신 제외. APFS volume 은 wholeBSD 와 prefix 다를 수 있어 누락될 수 있음 →
            // 호출자가 enumerate-all 후 filter 하는 별도 helper 필요할 수 있지만,
            // 보통 케이스 (HFS+, exFAT, MS-DOS, APFS Container) 는 prefix 로 잡힘.
            guard bsd.hasPrefix(wholeBSD), bsd != wholeBSD else { continue }
            // Leaf=true (실제 mountable file system) 만.
            // APFS Container 는 leaf=false, 실제 mount 대상은 그 안의 volume (synth disk).
            // synth disk 는 "diskN" 이름이지 wholeBSD prefix 아님 → 다른 경로로 처리.
            if let leafCF = IORegistryEntryCreateCFProperty(svc, "Leaf" as CFString, kCFAllocatorDefault, 0) {
                let leaf = leafCF.takeRetainedValue() as? Bool ?? false
                guard leaf else { continue }
            }
            result.append(bsd)
        }

        // APFS Container 처리: wholeBSD 안의 APFS Container 가 있으면 그 container 의 synth disk 들도 추가.
        // child partition 중 Content == "Apple_APFS" 인 게 있으면, ParentBSD == 그것인 synth disk 들 enumerate.
        let apfsContainerBSDs = result.filter { isAPFSContainer($0) }
        if !apfsContainerBSDs.isEmpty {
            let synthVolumes = enumerateSynthesizedAPFSVolumes(forContainerBSDs: Set(apfsContainerBSDs))
            // container 자체는 mount 대상 아님 — 제거하고 synth volumes 추가
            result.removeAll { apfsContainerBSDs.contains($0) }
            result.append(contentsOf: synthVolumes)
        }

        return result
    }

    /// 주어진 BSD name 의 IOMedia 가 APFS container 인지 검사.
    private func isAPFSContainer(_ bsd: String) -> Bool {
        guard let disk = self.disk(forBSDName: bsd),
              let desc = description(for: disk) else { return false }
        let content = desc[kDADiskDescriptionMediaContentKey as String] as? String ?? ""
        return content == "Apple_APFS"
    }

    /// APFS synth volumes 전체 enumerate — `diskN` 이름이고 ParentMedia 가 주어진 container BSD.
    /// IOMedia property 의 `BSD Name` 이 "diskN" (synth) 인 항목들 중, IORegistry parent chain 에
    /// container BSD 가 포함되는 것만.
    private func enumerateSynthesizedAPFSVolumes(forContainerBSDs containers: Set<String>) -> [String] {
        guard let matching = IOServiceMatching("IOMedia") else { return [] }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iter) }

        var result: [String] = []
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            guard let bsd = bsdName(of: svc) else { continue }
            // synth volume 은 leaf=true, whole=true (자신이 whole disk).
            let leaf = (IORegistryEntryCreateCFProperty(svc, "Leaf" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? Bool) ?? false
            guard leaf else { continue }
            // parent IORegistry entry 들을 traversing 해서 container BSD 매칭.
            if hasParentBSD(of: svc, in: containers) {
                result.append(bsd)
            }
        }
        return result
    }

    /// IORegistry entry 의 parent chain 에서 BSD Name 이 set 에 포함된 것이 있는지.
    private func hasParentBSD(of svc: io_service_t, in set: Set<String>) -> Bool {
        var current: io_service_t = svc
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<10 {  // depth 가드
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0 else { return false }
            // 다음 단계로 이동하기 전, 부모 검사
            if let pBSD = bsdName(of: parent), set.contains(pBSD) {
                IOObjectRelease(parent)
                return true
            }
            IOObjectRelease(current)
            current = parent
        }
        return false
    }

    /// IOMedia 의 "BSD Name" property 추출.
    private func bsdName(of svc: io_service_t) -> String? {
        let cf = IORegistryEntryCreateCFProperty(svc, "BSD Name" as CFString, kCFAllocatorDefault, 0)
        return cf?.takeRetainedValue() as? String
    }

    private static let virtualProtocols: Set<String> = [
        "Disk Image", "Virtual Interface", "Disk Image (UDIF)"
    ]
}

// MARK: - Helpers

/// callback ↔ caller 간 결과 전달용 reference box.
/// closure 가 C function pointer 로 캐스팅되어 self 캡처 불가하므로 Unmanaged 로 우회.
private final class ResultBox {
    var result: DAResult?
    var semaphore = DispatchSemaphore(value: 0)
}

/// DADissenter 가 reason 문자열을 안 주는 케이스 — status code 만으로 단서 만들기.
private func unixDescription(forStatus status: DAReturn) -> String {
    // DAReturn 은 보통 unix errno (EBUSY=16 등) 또는 framework 정의 코드.
    let errno = Int32(status & 0xFF)
    if let cstr = strerror(errno) {
        return String(cString: cstr)
    }
    return "DA status 0x\(String(status, radix: 16))"
}
