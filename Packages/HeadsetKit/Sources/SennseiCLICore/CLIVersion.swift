/// The single version string for the command line tool. It must equal CFBundleShortVersionString in
/// Tools/app/Info.plist (a test enforces this); `sennsei --version` and `sennsei doctor` both print it.
public enum CLIVersion {
    public static let current = "0.1.0"
}
