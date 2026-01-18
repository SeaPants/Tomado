import Foundation

extension FileManager {
  /// アプリケーションのストレージディレクトリのURLを取得
  /// ディレクトリが存在しない場合は作成する
  func appStorageURL() -> URL {
    let appSupportURL = urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let storageURL = appSupportURL.appendingPathComponent("com.tomado.app", isDirectory: true)

    // ディレクトリが存在しない場合は作成
    try? createDirectory(at: storageURL, withIntermediateDirectories: true)

    return storageURL
  }
}
