import Darwin
import Foundation
import TunnelGuardCore

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

guard CommandLine.arguments.count == 2 else {
    fail("Использование: tunnelguard-check-profile /путь/к/профилю.json", status: 64)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let profile = try? Data(contentsOf: url) else {
    fail("Не удалось прочитать локальный файл профиля.", status: 66)
}

do {
    try SingBoxProfile.validate(profile)
    print("Профиль соответствует схеме для испытаний. Фактическая маршрутизация ещё не проверена.")
} catch {
    fail(String(describing: error), status: 65)
}
