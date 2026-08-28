import Foundation

enum L10nCore {
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = Bundle.module.localizedString(forKey: key, value: nil, table: "Localizable")
        if args.isEmpty { return format }
        return String(format: format, locale: Locale.current, arguments: args)
    }
}
