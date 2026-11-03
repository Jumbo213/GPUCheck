import Foundation
import Security

// Compiled as the separate SSH_ASKPASS executable, never linked into GPUCheck.
// SSH receives the password over this process's standard output; no credential
// is placed in arguments, on disk, or in application diagnostics.
guard let account = ProcessInfo.processInfo.environment["GPUCHECK_KEYCHAIN_ACCOUNT"],
      !account.isEmpty else {
    exit(1)
}

let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "GPUCheck.SSH",
    kSecAttrAccount as String: account,
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne
]
var item: CFTypeRef?
guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let password = String(data: data, encoding: .utf8),
      !password.isEmpty else {
    exit(1)
}
FileHandle.standardOutput.write(Data((password + "\n").utf8))
