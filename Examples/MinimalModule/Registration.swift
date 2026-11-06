import GlacierBuiltins

/// Pass this list to Glacier's `additionalModules` composition argument in a fork.
/// The package's normal production catalogue does not include TextTrimModule.
public enum MinimalModuleRegistration {
    public static let additionalModules: [AnyGlacierToolModule] = [
        AnyGlacierToolModule(TextTrimModule()),
    ]
}
