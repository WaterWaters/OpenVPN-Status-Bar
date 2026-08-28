import Foundation

enum L10n {
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = Bundle.module.localizedString(forKey: key, value: nil, table: "Localizable")
        if args.isEmpty { return format }
        return String(format: format, locale: Locale.current, arguments: args)
    }

    // Common
    static var appName: String { tr("app.name") }
    // ContentView
    static var autoReconnect: String { tr("autoreconnect.title") }
    static var settings: String { tr("settings.title") }
    static var log: String { tr("log.title") }
    static var notConfigured: String { tr("notConfigured") }
    static var quit: String { tr("quit") }
    static var authEngine: String { tr("auth.engine") }
    static var connectionConfig: String { tr("connection.config") }
    static var noLog: String { tr("log.empty") }
    static var nextStep: String { tr("wizard.next") }
    static var username: String { tr("wizard.username") }
    static var password: String { tr("wizard.password") }
    static var saveAndFinish: String { tr("wizard.save") }
    static var done: String { tr("wizard.done") }
    static var dropOvpn: String { tr("wizard.drop") }
    static var selectFile: String { tr("wizard.selectFile") }
}
