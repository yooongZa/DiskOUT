/// 외장 저장장치 표시 여부의 공통 판정.
///
/// macOS 는 내장 SDXC reader(리더)에 꽂힌 SD 카드를 `Internal=true` 로 보고한다.
/// 내장 SSD와 구분하기 위해 Secure Digital protocol(프로토콜)이면서 실제로 분리 가능한
/// media(매체)인 경우에만 internal(내장) 예외를 허용한다.
enum ExternalMediaPolicy {
    static func shouldInclude(
        isInternal: Bool,
        busProtocol: String?,
        isRemovable: Bool?,
        isEjectable: Bool?
    ) -> Bool {
        if !isInternal { return true }

        return busProtocol == "Secure Digital"
            && (isRemovable == true || isEjectable == true)
    }
}
