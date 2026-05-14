//
//  main.swift
//  DiskOUT — 명시적 entry point (구 EjectDrives)
//
//  @main attribute 가 swiftc 단독 빌드 + macOS 26 환경에서 안정적이지 않아
//  명시적으로 NSApplication 라이프사이클을 시작한다.
//

import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // run() 전에 호출 — LSUIElement + open 조합 안정화
let delegate = AppDelegate()
app.delegate = delegate
app.run()
