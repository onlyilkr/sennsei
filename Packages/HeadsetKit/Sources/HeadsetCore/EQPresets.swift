/// Built-in equalizer presets for ACCENTUM (five bands: 50 / 250 / 800 / 3000 / 8000 Hz, in dB).
public enum EQPresets {
    public static let accentum: [(name: String, gains: [Double])] = [
        ("Rock", [0, 0, 3, 3, -1]),
        ("Pop", [0, -5, 0, 5, 0]),
        ("Dance", [2, -3, -3, 1, 1]),
        ("Hip-Hop", [3, -1, -4, 2, 0]),
        ("Classical", [0, 0, 0, 1, 2]),
        ("Movie", [0, 0, 2, 2, -1]),
        ("Jazz", [-3, 0, 2, 2, 0]),
        ("Flat", [0, 0, 0, 0, 0]),
    ]
}
