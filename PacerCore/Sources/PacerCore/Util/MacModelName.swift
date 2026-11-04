import Foundation

/// A readable name for a Mac's `hw.model` identifier ("Mac16,8" becomes
/// "MacBook Pro 14-inch (M4 Pro, 2024)"), so the telemetry dashboard can group
/// Macs by something a person recognises.
///
/// Apple-silicon Macs from 2020 on. Only identifiers known for certain are
/// listed; anything else comes back as the raw identifier, never a guess.
/// Deliberately left unmapped because the chip/size split could not be
/// confirmed from memory: Mac15,8 to Mac15,11 (M3 Pro/Max MacBook Pro
/// variants), Mac16,5 and Mac16,6 (M4 Max MacBook Pro), Mac15,14 and Mac16,9
/// (newer Mac Studio), Mac17,x other than Mac17,2. Add them when verified.
public enum MacModelName {

    public static func name(for identifier: String) -> String {
        table[identifier] ?? identifier
    }

    static let table: [String: String] = [
        // 2020
        "MacBookAir10,1": "MacBook Air (M1, 2020)",
        "MacBookPro17,1": "MacBook Pro 13-inch (M1, 2020)",
        "Macmini9,1": "Mac mini (M1, 2020)",
        // 2021
        "iMac21,1": "iMac 24-inch (M1, 2021)",
        "iMac21,2": "iMac 24-inch (M1, 2021)",
        "MacBookPro18,1": "MacBook Pro 16-inch (M1 Pro, 2021)",
        "MacBookPro18,2": "MacBook Pro 16-inch (M1 Max, 2021)",
        "MacBookPro18,3": "MacBook Pro 14-inch (M1 Pro, 2021)",
        "MacBookPro18,4": "MacBook Pro 14-inch (M1 Max, 2021)",
        // 2022
        "Mac13,1": "Mac Studio (M1 Max, 2022)",
        "Mac13,2": "Mac Studio (M1 Ultra, 2022)",
        "Mac14,2": "MacBook Air 13-inch (M2, 2022)",
        "Mac14,7": "MacBook Pro 13-inch (M2, 2022)",
        // 2023
        "Mac14,3": "Mac mini (M2, 2023)",
        "Mac14,12": "Mac mini (M2 Pro, 2023)",
        "Mac14,5": "MacBook Pro 14-inch (M2 Max, 2023)",
        "Mac14,6": "MacBook Pro 16-inch (M2 Max, 2023)",
        "Mac14,9": "MacBook Pro 14-inch (M2 Pro, 2023)",
        "Mac14,10": "MacBook Pro 16-inch (M2 Pro, 2023)",
        "Mac14,8": "Mac Pro (M2 Ultra, 2023)",
        "Mac14,13": "Mac Studio (M2 Max, 2023)",
        "Mac14,14": "Mac Studio (M2 Ultra, 2023)",
        "Mac14,15": "MacBook Air 15-inch (M2, 2023)",
        "Mac15,3": "MacBook Pro 14-inch (M3, 2023)",
        "Mac15,4": "iMac 24-inch (M3, 2023)",
        "Mac15,5": "iMac 24-inch (M3, 2023)",
        "Mac15,6": "MacBook Pro 14-inch (M3 Pro, 2023)",
        "Mac15,7": "MacBook Pro 16-inch (M3 Pro, 2023)",
        // 2024
        "Mac15,12": "MacBook Air 13-inch (M3, 2024)",
        "Mac15,13": "MacBook Air 15-inch (M3, 2024)",
        "Mac16,1": "MacBook Pro 14-inch (M4, 2024)",
        "Mac16,2": "iMac 24-inch (M4, 2024)",
        "Mac16,3": "iMac 24-inch (M4, 2024)",
        "Mac16,7": "MacBook Pro 16-inch (M4 Pro, 2024)",
        "Mac16,8": "MacBook Pro 14-inch (M4 Pro, 2024)",
        "Mac16,10": "Mac mini (M4, 2024)",
        "Mac16,11": "Mac mini (M4 Pro, 2024)",
        // 2025
        "Mac16,12": "MacBook Air 13-inch (M4, 2025)",
        "Mac16,13": "MacBook Air 15-inch (M4, 2025)",
        "Mac17,2": "MacBook Pro 14-inch (M5, 2025)",
    ]
}
