import Foundation

/// Which SDK module declares a type or a free function, for references the repository cannot resolve
/// (`Transaction.updates` → StoreKit, `MTLBuffer` → Metal, `pwrite` → Darwin).
///
/// A built-in table, seeded from the framework receivers the benchmark repositories leave unresolved, plus
/// prefix rules for the SDK naming conventions (`UI…` UIKit, `MTL…` Metal, `HK…` HealthKit). Nothing here
/// touches the network or the local SDKs.
public enum FrameworkCatalog {
    /// Imports present in almost every file. They never decide which module an unknown type comes from.
    public static let ubiquitousModules: Set<String> = [
        "Foundation", "SwiftUI", "UIKit", "AppKit", "Cocoa", "Combine", "Observation", "os", "OSLog", "CoreGraphics",
        "Darwin", "Dispatch", "Swift", "CoreFoundation", "_Concurrency",
    ]

    /// UI frameworks that declare far more names than this catalog lists, so a file importing one of them cannot
    /// attribute an unlisted name to its other imports.
    public static let uiFrameworks: Set<String> = ["SwiftUI", "UIKit", "AppKit", "Cocoa", "WatchKit"]

    /// In-app purchase and subscription SDKs (module or package names), for finding purchase code.
    public static let inAppPurchaseSDKs: Set<String> = [
        "StoreKit", "RevenueCat", "RevenueCatUI", "Purchases", "PurchasesHybridCommon", "Adapty", "AdaptyUI", "Qonversion",
        "SuperwallKit", "Glassfy", "ApphudSDK", "Apphud", "react-native-purchases", "react-native-purchases-ui",
        "react-native-iap", "expo-in-app-purchases", "expo-iap", "react-native-adapty", "@revenuecat/purchases-js",
        "@revenuecat/purchases-capacitor", "purchases_flutter", "in_app_purchase",
    ]

    /// The module that declares `name` (a type, or a dotted path such as `Product.SubscriptionPeriod`). When
    /// several frameworks declare it (`Transaction`: StoreKit and SwiftUI), the one `imports` names wins.
    public static func module(forType name: String, imports: Set<String> = []) -> String? {
        pick(typeCandidates(name), imports: imports)
    }

    /// The module that declares a free function (`pwrite` → Darwin, `XCTAssertEqual` → XCTest).
    public static func module(forFunction name: String, imports: Set<String> = []) -> String? {
        if let module = functions[name] { return module }
        for (prefix, module) in functionPrefixes where name.hasPrefix(prefix) { return module }
        // `CGImageSourceCreateWithURL`, `SecItemAdd`: C APIs named after their type.
        return pick(prefixCandidates(name), imports: imports)
    }

    /// Framework protocols a framework type adopts, whose repository extensions it reaches: `Text(…).dataLabel()`
    /// calls the repository's `extension View { func dataLabel() }`.
    public static func protocols(of type: String) -> [String] {
        if shapes.contains(type) { return ["Shape", "View"] }
        if views.contains(type) { return ["View"] }
        return []
    }

    /// The members a standard protocol gives its adopters, for the protocols whose members are all known: a member
    /// none of a type's protocols gives (`append` on a `Sendable` type) is not a framework member. Nil for the rest.
    public static func knownMembers(ofProtocol name: String) -> Set<String>? {
        protocolMembers[name]
    }

    /// Types an enum can name as its raw type. Such a parent gives the enum `rawValue`, nothing of its own.
    public static let rawValueTypes: Set<String> = [
        "String", "Character", "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "Float16", "CGFloat",
    ]

    private static let protocolMembers: [String: Set<String>] = [
        "Sendable": [], "SendableMetatype": [], "BitwiseCopyable": [], "Copyable": [], "Escapable": [], "AnyObject": [],
        "Equatable": [], "Comparable": [],
        "Hashable": ["hashValue", "hash"],
        "Encodable": ["encode"], "Decodable": ["init"], "Codable": ["encode", "init"],
        "Identifiable": ["id"],
        "CaseIterable": ["allCases"],
        "RawRepresentable": ["rawValue", "init"],
        "CustomStringConvertible": ["description"], "CustomDebugStringConvertible": ["debugDescription"],
        "LosslessStringConvertible": ["description", "init"],
        "Error": ["localizedDescription"],
        "LocalizedError": ["errorDescription", "failureReason", "recoverySuggestion", "helpAnchor", "localizedDescription"],
        "CodingKey": ["stringValue", "intValue", "init"],
        "Actor": ["unownedExecutor", "assumeIsolated", "preconditionIsolated", "assertIsolated"],
    ]

    private static let shapes: Set<String> = [
        "Circle", "Rectangle", "RoundedRectangle", "Capsule", "Ellipse", "UnevenRoundedRectangle", "ContainerRelativeShape",
        "Path", "AnyShape",
    ]

    /// SwiftUI (and SwiftUI-based framework) views.
    private static let views: Set<String> = [
        "Text", "Image", "Button", "Label", "Link", "HStack", "VStack", "ZStack", "LazyVStack", "LazyHStack", "LazyVGrid",
        "LazyHGrid", "Grid", "GridRow", "List", "ForEach", "Section", "ScrollView", "ScrollViewReader", "NavigationStack",
        "NavigationView", "NavigationLink", "NavigationSplitView", "TabView", "Toggle", "TextField", "SecureField",
        "TextEditor", "Picker", "DatePicker", "ColorPicker", "Slider", "Stepper", "ProgressView", "Gauge", "Menu", "Spacer",
        "Divider", "Group", "GroupBox", "Form", "LabeledContent", "DisclosureGroup", "ShareLink", "Canvas",
        "GeometryReader", "TimelineView", "Color", "LinearGradient", "RadialGradient", "AngularGradient",
        "EllipticalGradient", "MeshGradient", "AnyView", "EmptyView", "EquatableView", "ContentUnavailableView",
        "AsyncImage", "Table", "OutlineGroup", "EditButton", "RenameButton", "PasteButton", "ControlGroup", "ViewThatFits",
        "GlassEffectContainer", "SubscriptionStoreView", "StoreView", "ProductView", "SubscriptionOfferView", "Map",
        "VideoPlayer", "PhotosPicker", "SignInWithAppleButton", "SceneView", "SpriteView", "RealityView", "TipView",
        "Chart", "WebView",
    ]

    /// Every module that might declare the type, most likely first.
    public static func typeCandidates(_ name: String) -> [String] {
        if let modules = types[name] { return modules }
        let first = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
        if first != name, let modules = types[first] { return modules }
        return prefixCandidates(first)
    }

    private static func pick(_ candidates: [String], imports: Set<String>) -> String? {
        guard let first = candidates.first else { return nil }
        if candidates.count > 1, let imported = candidates.first(where: { imports.contains($0) }) { return imported }
        return first
    }

    /// SDK naming conventions: a module prefix followed by an uppercase letter (`UIColor`, `MTLDevice`).
    private static func prefixCandidates(_ name: String) -> [String] {
        let characters = Array(name)
        for (prefix, modules) in typePrefixes {
            let count = prefix.count
            guard characters.count > count, name.hasPrefix(prefix), characters[count].isUppercase else { continue }
            return modules
        }
        return []
    }

    /// Longest prefixes first.
    private static let typePrefixes: [(String, [String])] = [
        ("XCUI", ["XCTest"]), ("XCT", ["XCTest"]), ("SCN", ["SceneKit"]), ("MTL", ["Metal"]), ("MPS", ["MetalPerformanceShaders"]),
        ("PDF", ["PDFKit"]), ("UI", ["UIKit"]), ("NS", ["Foundation", "AppKit", "CoreData"]), ("CG", ["CoreGraphics"]),
        ("CA", ["QuartzCore"]), ("CI", ["CoreImage"]), ("CV", ["CoreVideo"]), ("CM", ["CoreMedia", "CoreMotion"]),
        ("CF", ["CoreFoundation"]), ("CT", ["CoreText"]), ("HK", ["HealthKit"]), ("PH", ["Photos", "PhotosUI"]),
        ("UN", ["UserNotifications"]), ("AV", ["AVFoundation", "AVKit"]), ("SF", ["Speech", "SafariServices"]),
        ("MK", ["MapKit"]), ("CL", ["CoreLocation"]), ("EK", ["EventKit"]), ("CK", ["CloudKit"]), ("CN", ["Contacts"]),
        ("GK", ["GameKit", "GameplayKit"]), ("SK", ["SpriteKit", "StoreKit"]), ("WC", ["WatchConnectivity"]),
        ("WK", ["WebKit", "WatchKit"]), ("NL", ["NaturalLanguage"]), ("ML", ["CoreML"]), ("VN", ["Vision", "VisionKit"]),
        ("BG", ["BackgroundTasks"]), ("LA", ["LocalAuthentication"]), ("NW", ["Network"]), ("AS", ["AuthenticationServices"]),
        ("CS", ["CoreSpotlight"]), ("LP", ["LinkPresentation"]), ("QL", ["QuickLook"]), ("AR", ["ARKit"]),
        ("CH", ["CoreHaptics"]), ("MF", ["MessageUI"]), ("Sec", ["Security"]),
    ]

    private static let functionPrefixes: [(String, String)] = [
        ("XCTAssert", "XCTest"), ("sqlite3_", "SQLite3"), ("vDSP_", "Accelerate"), ("vImage", "Accelerate"),
        ("cblas_", "Accelerate"), ("dispatch_", "Dispatch"), ("pthread_", "Darwin"), ("os_", "os"), ("objc_", "ObjectiveC"),
        ("CC_", "CommonCrypto"), ("kSec", "Security"), ("simd_", "simd"), ("compression_", "Compression"),
        ("COMPRESSION_", "Compression"), ("kCGImage", "ImageIO"),
    ]

    private static let functions: [String: String] = {
        var table: [String: String] = [:]
        func add(_ module: String, _ names: [String]) { for name in names { table[name] = module } }
        add("Darwin", [
            "pwrite", "pread", "fsync", "fcntl", "mmap", "munmap", "msync", "madvise", "ftruncate", "lseek", "fstat", "stat",
            "lstat", "unlink", "rename", "flock", "getpid", "getenv", "setenv", "unsetenv", "strerror", "memcpy", "memmove",
            "memset", "memcmp", "malloc", "calloc", "realloc", "free", "posix_memalign", "usleep", "nanosleep", "sleep",
            "mach_absolute_time", "mach_timebase_info", "sysctlbyname", "sysctl", "dlopen", "dlsym", "dlclose", "arc4random",
            "arc4random_uniform", "arc4random_buf", "strlen", "strcmp", "strncmp", "strdup", "fopen", "fclose", "fread",
            "fwrite", "fflush", "fileno", "dup", "dup2", "pipe", "kill", "signal", "exit", "abort", "close", "realpath",
            "mkdir", "rmdir", "opendir", "readdir", "closedir", "access", "chmod", "fchmod", "getcwd", "chdir", "time",
            "clock_gettime", "gettimeofday", "posix_spawn", "waitpid", "isatty", "ioctl", "socket", "bind", "listen",
            "accept", "connect", "send", "recv", "setsockopt", "getaddrinfo", "freeaddrinfo", "inet_pton", "htons", "ntohs",
            "errno", "getpagesize", "off_t", "mode_t", "size_t", "ssize_t", "pid_t", "time_t", "timespec", "timeval",
            // C math, which Swift code calls unqualified.
            "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "exp", "exp2", "expm1", "log",
            "log2", "log10", "log1p", "pow", "sqrt", "cbrt", "hypot", "floor", "ceil", "round", "trunc", "fabs", "fmod",
            "remainder", "fmin", "fmax", "copysign", "lround", "rint", "modf", "frexp", "ldexp", "erf", "tgamma", "lgamma",
        ])
        add("Accelerate", ["vDSP", "vForce"])
        add("XCTest", [
            "XCTFail", "XCTUnwrap", "XCTSkip", "XCTSkipIf", "XCTSkipUnless", "XCTExpectFailure", "XCTExpectedFailure",
        ])
        add("Testing", ["confirmation", "withKnownIssue"])
        add("Metal", ["MTLCreateSystemDefaultDevice", "MTLCopyAllDevices"])
        add("Security", ["SecItemAdd", "SecItemCopyMatching", "SecItemUpdate", "SecItemDelete", "SecRandomCopyBytes"])
        add("CoreGraphics", ["CGRectMake", "CGPointMake", "CGSizeMake"])
        add("os", ["os_log", "os_signpost"])
        add("Observation", ["withObservationTracking"])
        add("SwiftUI", ["withAnimation", "withTransaction"])
        add("Foundation", ["NSLocalizedString", "NSStringFromClass", "NSClassFromString", "NSHomeDirectory", "NSTemporaryDirectory"])
        add("Swift", [
            "withCheckedContinuation", "withCheckedThrowingContinuation", "withUnsafeContinuation", "withTaskGroup",
            "withThrowingTaskGroup", "withDiscardingTaskGroup", "withThrowingDiscardingTaskGroup", "withTaskCancellationHandler",
            "withUnsafeBytes", "withUnsafeMutableBytes", "withUnsafePointer", "withUnsafeMutablePointer", "withExtendedLifetime",
            "unsafeBitCast", "numericCast", "swap", "repeatElement", "sequence", "readLine", "dump", "isKnownUniquelyReferenced",
            "withoutActuallyEscaping", "autoreleasepool",
        ])
        return table
    }()

    private static let types: [String: [String]] = {
        var table: [String: [String]] = [:]
        func add(_ module: String, _ names: [String]) {
            for name in names { table[name, default: []].append(module) }
        }
        add("StoreKit", [
            "Transaction", "Product", "AppStore", "AppTransaction", "StoreKitError", "VerificationResult", "Storefront",
            "SKPaymentQueue", "SKProduct", "SKProductsRequest", "SKProductsResponse", "SKPayment", "SKMutablePayment",
            "SKPaymentTransaction", "SKStoreReviewController", "SKReceiptRefreshRequest", "StoreView", "ProductView",
            "SubscriptionStoreView", "SubscriptionOfferView", "RequestReviewAction", "PurchaseAction", "Message",
        ])
        add("SwiftUI", [
            "Color", "Font", "Text", "Image", "View", "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack", "LazyVGrid",
            "LazyHGrid", "GridItem", "Grid", "GridRow", "List", "ForEach", "Section", "ScrollView", "ScrollViewReader",
            "ScrollViewProxy", "ScrollPosition", "NavigationStack", "NavigationView", "NavigationLink", "NavigationPath",
            "NavigationSplitView", "TabView", "Tab", "Button", "Toggle", "TextField", "SecureField", "TextEditor", "Picker",
            "DatePicker", "ColorPicker", "Slider", "Stepper", "ProgressView", "Gauge", "Label", "Link", "Menu", "Spacer",
            "Divider", "Group", "GroupBox", "Form", "LabeledContent", "DisclosureGroup", "ShareLink", "Canvas",
            "GeometryReader", "GeometryProxy", "TimelineView", "Shape", "Path", "Circle", "Rectangle", "RoundedRectangle",
            "Capsule", "Ellipse", "UnevenRoundedRectangle", "ContainerRelativeShape", "LinearGradient", "RadialGradient",
            "AngularGradient", "EllipticalGradient", "Gradient", "MeshGradient", "AnyView", "EmptyView", "EquatableView",
            "Animation", "Transaction", "Binding", "State", "StateObject", "ObservedObject", "EnvironmentObject",
            "Environment", "EnvironmentValues", "Namespace", "FocusState", "FocusedValue", "AppStorage", "SceneStorage",
            "Bindable", "App", "Scene", "WindowGroup", "Settings", "DocumentGroup", "Window", "MenuBarExtra", "Edge",
            "EdgeInsets", "Alignment", "HorizontalAlignment", "VerticalAlignment", "Angle", "UnitPoint", "Axis",
            "ContentMode", "ColorScheme", "DynamicTypeSize", "ToolbarItem", "ToolbarItemGroup", "ToolbarItemPlacement",
            "ButtonStyle", "PrimitiveButtonStyle", "ViewModifier", "PreferenceKey", "EnvironmentKey", "AnyTransition",
            "AnyShape", "ShapeStyle", "AnyShapeStyle", "Material", "ContentUnavailableView", "ImageRenderer", "Layout",
            "ViewBuilder", "ScenePhase", "DismissAction", "OpenURLAction", "Visibility", "LayoutDirection",
            "GraphicsContext", "KeyPress", "SensoryFeedback", "ScrollEdgeEffectStyle", "Glass", "GlassEffectContainer",
            "AccessibilityNotification", "UIHostingController", "NSHostingView", "NSHostingController", "UIViewRepresentable",
            "UIViewControllerRepresentable", "NSViewRepresentable", "TextSelection", "AttributedTextSelection",
            "PresentationDetent", "SubmitLabel", "ProposedViewSize", "ViewDimensions", "Toolbar", "AsyncImage", "Table",
            "TableColumn", "OutlineGroup", "EditButton", "RenameButton", "PasteButton", "ControlGroup", "ViewThatFits",
            "AnyLayout", "ZStackLayout", "VStackLayout", "HStackLayout", "SpatialTapGesture", "TapGesture",
            "DragGesture", "LongPressGesture", "MagnifyGesture", "RotateGesture", "GestureState", "Spring",
            "UnitCurve", "KeyframeAnimator", "PhaseAnimator", "CustomAnimation", "Text.Scale", "Font.Weight",
            "Font.Design", "Image.Scale", "EditMode",
        ])
        add("Charts", [
            "Chart", "BarMark", "LineMark", "PointMark", "AreaMark", "RuleMark", "SectorMark", "RectangleMark",
            "AxisMarks", "AxisValueLabel", "AxisGridLine", "AxisTick", "ChartProxy", "PlottableValue",
        ])
        add("Foundation", [
            "FileManager", "URLSession", "URLSessionConfiguration", "URLSessionDataTask", "URLRequest", "URLResponse",
            "HTTPURLResponse", "URL", "URLComponents", "URLQueryItem", "URLError", "UserDefaults", "ProcessInfo", "Bundle",
            "Calendar", "Date", "DateComponents", "DateFormatter", "DateInterval", "DateComponentsFormatter",
            "ISO8601DateFormatter", "RelativeDateTimeFormatter", "NumberFormatter", "MeasurementFormatter",
            "ByteCountFormatter", "ListFormatter", "PersonNameComponentsFormatter", "Locale", "TimeZone", "Data",
            "JSONEncoder", "JSONDecoder", "JSONSerialization", "PropertyListEncoder", "PropertyListDecoder",
            "PropertyListSerialization", "NotificationCenter", "Notification", "Timer", "Thread", "OperationQueue",
            "Operation", "BlockOperation", "NSLock", "NSRecursiveLock", "NSCondition", "NSRegularExpression", "NSString",
            "NSAttributedString", "NSMutableAttributedString", "AttributedString", "CharacterSet", "Scanner", "NSError",
            "UUID", "Decimal", "NSNumber", "IndexSet", "IndexPath", "NSRange", "Measurement", "UnitLength", "UnitDuration",
            "UnitMass", "UnitTemperature", "UnitSpeed", "UnitEnergy", "FileHandle", "Pipe", "Process",
            "NSTextCheckingResult", "NSCoder", "NSKeyedArchiver", "NSKeyedUnarchiver", "NSPredicate", "NSSortDescriptor",
            "SortDescriptor", "Predicate", "FormatStyle", "NSCache", "NSObject", "Progress", "RunLoop", "NSMetadataQuery",
            "NSUbiquitousKeyValueStore", "NSFileCoordinator", "NSDataDetector", "LocalizedStringResource",
            "LocalizedStringKey", "NSItemProvider", "DecodingError", "EncodingError", "CocoaError", "POSIXError",
            "ByteCountFormatStyle", "Morphology", "InflectionRule", "OutputStream", "InputStream", "Host",
            "PersonNameComponents", "NSNull", "NSURL", "NSData", "NSDictionary", "NSArray", "NSSet", "NSValue",
            "DistributedNotificationCenter", "NSUserActivity", "AffineTransform", "FileWrapper", "XMLParser",
            "NSOrderedSet", "NSMutableData", "NSMutableString", "Date.FormatStyle", "Locale.Region", "UndoManager", "LocalizedError",
        ])
        add("Swift", [
            "Task", "TaskGroup", "ThrowingTaskGroup", "DiscardingTaskGroup", "AsyncStream", "AsyncThrowingStream",
            "CheckedContinuation", "UnsafeContinuation", "MainActor", "Duration", "ContinuousClock", "SuspendingClock",
            "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Double", "Float",
            "Float16", "Bool", "String", "Substring", "Character", "Unicode", "Array", "Dictionary", "Set", "Optional",
            "Result", "Range", "ClosedRange", "Never", "MemoryLayout", "UnsafeMutableRawPointer", "UnsafeRawPointer",
            "UnsafeMutablePointer", "UnsafePointer", "UnsafeBufferPointer", "UnsafeMutableBufferPointer",
            "UnsafeRawBufferPointer", "UnsafeMutableRawBufferPointer", "Unmanaged", "ObjectIdentifier", "KeyPath",
            "WritableKeyPath", "ReferenceWritableKeyPath", "AnyHashable", "Hasher", "SystemRandomNumberGenerator", "Mirror",
            "CancellationError", "OpaquePointer", "Slice", "ArraySlice", "ContiguousArray", "AnyIterator", "AnySequence",
            "AnyCollection", "StrideTo", "StrideThrough", "TaskPriority", "TaskLocal", "Comparable", "Equatable",
            "Hashable", "Codable", "Decodable", "Encodable", "Identifiable", "CaseIterable", "Sendable", "Error",
            "CustomStringConvertible", "RawRepresentable", "Sequence", "Collection", "OptionSet", "SetAlgebra",
            "IteratorProtocol", "AsyncSequence", "Actor", "GlobalActor", "Clock", "InstantProtocol", "RandomNumberGenerator",
            "Encoder", "Decoder", "CodingKey", "KeyedEncodingContainer", "KeyedDecodingContainer", "UnkeyedEncodingContainer",
            "UnkeyedDecodingContainer", "SingleValueEncodingContainer", "SingleValueDecodingContainer",
            "CustomDebugStringConvertible", "LosslessStringConvertible", "StringProtocol", "BinaryInteger", "FixedWidthInteger",
            "FloatingPoint", "BinaryFloatingPoint", "Numeric", "Strideable", "RangeExpression",
        ])
        add("Synchronization", ["Mutex", "Atomic"])
        add("Dispatch", [
            "DispatchQueue", "DispatchGroup", "DispatchSemaphore", "DispatchWorkItem", "DispatchTime", "DispatchWallTime",
            "DispatchSource", "DispatchTimeInterval", "DispatchQoS", "DispatchData",
        ])
        add("UIKit", [
            "UIColor", "UIFont", "UIImage", "UIApplication", "UIDevice", "UIScreen", "UIView", "UIViewController",
            "UIWindow", "UIWindowScene", "UIScene", "UIPasteboard", "UIScrollView", "UITableView", "UICollectionView",
            "UILabel", "UIButton", "UIImageView", "UIStackView", "UINavigationController", "UIAccessibility",
            "UIImpactFeedbackGenerator", "UINotificationFeedbackGenerator", "UISelectionFeedbackGenerator",
            "UIActivityViewController", "UIDocumentPickerViewController", "UIAlertController", "UIAlertAction",
            "UIBezierPath", "UIGraphicsImageRenderer", "UIEdgeInsets", "UIScrollEdgeEffect", "UIWritingToolsCoordinator",
            "UIContentSizeCategory", "UITraitCollection", "UIFontMetrics", "UIResponder", "UIGestureRecognizer",
            "UITapGestureRecognizer", "UIPanGestureRecognizer", "UIImagePickerController", "UIColorPickerViewController",
            "UIFeedbackGenerator", "UIMenu", "UIAction", "UIKeyCommand", "UIBarButtonItem", "UITextField", "UITextView",
        ])
        add("AppKit", [
            "NSColor", "NSFont", "NSImage", "NSApplication", "NSWorkspace", "NSPasteboard", "NSView", "NSViewController",
            "NSWindow", "NSWindowController", "NSMenu", "NSMenuItem", "NSStatusBar", "NSStatusItem", "NSAlert",
            "NSOpenPanel", "NSSavePanel", "NSEvent", "NSScreen", "NSCursor", "NSBezierPath", "NSTextField", "NSButton",
            "NSSound", "NSAppearance", "NSFontManager", "NSRunningApplication", "NSHapticFeedbackManager",
        ])
        add("CoreGraphics", [
            "CGFloat", "CGPoint", "CGSize", "CGRect", "CGAffineTransform", "CGColor", "CGColorSpace", "CGContext",
            "CGImage", "CGImageAlphaInfo", "CGBitmapInfo", "CGPath", "CGMutablePath", "CGVector", "CGBlendMode",
            "CGInterpolationQuality", "CGLineCap", "CGLineJoin", "CGGradient", "CGEvent",
        ])
        add("ImageIO", ["CGImageSource", "CGImageDestination"])
        add("CoreImage", ["CIImage", "CIFilter", "CIContext", "CIColor", "CIVector", "CIDetector"])
        add("Metal", [
            "MTLBuffer", "MTLCommandBuffer", "MTLCommandQueue", "MTLDevice", "MTLComputePipelineState",
            "MTLComputeCommandEncoder", "MTLLibrary", "MTLFunction", "MTLTexture", "MTLRenderPipelineState",
            "MTLResourceOptions", "MTLSize", "MTLRenderCommandEncoder", "MTLBlitCommandEncoder", "MTLTextureDescriptor",
        ])
        add("Accelerate", ["vDSP", "vImage", "BNNS", "vForce", "simd_float4x4", "simd_float3", "simd_float4"])
        add("CryptoKit", [
            "SHA256", "SHA384", "SHA512", "Insecure", "HMAC", "SymmetricKey", "AES", "ChaChaPoly", "P256", "P384",
            "Curve25519", "HKDF", "SealedBox",
        ])
        add("Security", ["SecKey", "SecAccessControl", "SecTrust", "SecCertificate", "SecIdentity"])
        add("XCTest", [
            "XCUIApplication", "XCUIElement", "XCUIElementQuery", "XCUIDevice", "XCUIScreen", "XCUIKeyboardKey",
            "XCUICoordinate", "XCTestCase", "XCTestExpectation", "XCTContext", "XCTExpectedFailure", "XCTSkip",
            "XCTAttachment", "XCTWaiter", "XCTNSPredicateExpectation", "XCTActivity", "XCTMeasureOptions",
            "XCTClockMetric", "XCTMemoryMetric", "XCTCPUMetric", "XCUIElement.ElementType",
        ])
        add("Testing", ["Issue", "Test", "Suite", "Tag", "Confirmation", "SourceLocation", "Trait"])
        add("WatchConnectivity", ["WCSession", "WCSessionDelegate", "WCSessionFile", "WCSessionUserInfoTransfer"])
        add("ActivityKit", [
            "Activity", "ActivityAttributes", "ActivityContent", "ActivityAuthorizationInfo", "ActivityState",
            "ActivityUIDismissalPolicy", "PushType", "AlertConfiguration",
        ])
        add("HealthKit", [
            "HKHealthStore", "HKWorkout", "HKWorkoutActivityType", "HKQuantityType", "HKQuantity", "HKUnit",
            "HKObjectType", "HKSampleType", "HKQuantitySample", "HKCategorySample", "HKCategoryType", "HKSampleQuery",
            "HKStatisticsQuery", "HKStatisticsCollectionQuery", "HKAnchoredObjectQuery", "HKObserverQuery",
            "HKWorkoutSession", "HKLiveWorkoutBuilder", "HKLiveWorkoutDataSource", "HKWorkoutConfiguration",
            "HKWorkoutBuilder", "HKStatistics", "HKQuery", "HKDevice", "HKSource", "HKAuthorizationStatus",
            "HKCharacteristicType", "HKWorkoutEvent", "HKWorkoutRoute", "HKWorkoutRouteBuilder",
            "HKQuantityTypeIdentifier", "HKSeriesBuilder", "HKHeartbeatSeriesSample", "HKSampleQueryDescriptor",
            "HKWorkoutSessionState", "HKError",
        ])
        add("SwiftData", [
            "ModelContainer", "ModelContext", "ModelConfiguration", "FetchDescriptor", "Schema", "SchemaMigrationPlan",
            "MigrationStage", "VersionedSchema", "Query", "PersistentIdentifier", "PersistentModel", "ModelActor",
            "FetchResultsCollection", "DefaultStore", "HistoryDescriptor",
        ])
        add("CoreData", [
            "NSManagedObjectContext", "NSPersistentContainer", "NSPersistentCloudKitContainer", "NSFetchRequest",
            "NSManagedObject", "NSManagedObjectModel", "NSMergePolicy", "NSEntityDescription",
            "NSPersistentStoreCoordinator", "NSBatchDeleteRequest", "NSPersistentStoreDescription", "FetchRequest",
            "FetchedResults",
        ])
        add("MapKit", [
            "MKLocalSearch", "MKLocalSearchCompleter", "MKMapItem", "MKPlacemark", "MKDirections", "MKRoute",
            "MKMapSnapshotter", "MKMapRect", "MKMapView", "MKCoordinateRegion", "MKCoordinateSpan", "MKPolyline",
            "MKPointAnnotation", "MKMapCamera", "MKLookAroundScene", "MKLookAroundSceneRequest", "Map",
            "MapCameraPosition", "Marker", "Annotation", "MapPolyline", "MKLocalPointsOfInterestRequest",
            "MKPointOfInterestCategory", "MKMapPoint", "MapCamera", "MapStyle", "MKAddress", "MKReverseGeocodingRequest",
        ])
        add("CoreLocation", [
            "CLLocationManager", "CLLocation", "CLLocationCoordinate2D", "CLGeocoder", "CLPlacemark",
            "CLAuthorizationStatus", "CLCircularRegion", "CLLocationDistance", "CLHeading", "CLLocationUpdate",
            "CLMonitor", "CLLocationDegrees",
        ])
        add("Photos", [
            "PHPhotoLibrary", "PHAsset", "PHImageManager", "PHFetchOptions", "PHAssetCollection", "PHImageRequestOptions",
            "PHAuthorizationStatus", "PHAssetChangeRequest", "PHCachingImageManager", "PHFetchResult",
        ])
        add("PhotosUI", ["PHPickerViewController", "PHPickerConfiguration", "PhotosPicker", "PhotosPickerItem"])
        add("AVFoundation", [
            "AVAudioSession", "AVAudioPlayer", "AVAudioRecorder", "AVAudioEngine", "AVPlayer", "AVPlayerItem", "AVAsset",
            "AVURLAsset", "AVSpeechSynthesizer", "AVSpeechUtterance", "AVSpeechSynthesisVoice", "AVCaptureSession",
            "AVCaptureDevice", "AVAudioFile", "AVAudioFormat", "AVAudioPCMBuffer", "AVAssetExportSession",
            "AVAssetImageGenerator", "AVPlayerLayer", "AVAudioPlayerNode", "AVCaptureVideoPreviewLayer",
        ])
        add("AVKit", ["VideoPlayer", "AVPlayerViewController", "AVRoutePickerView"])
        add("Speech", [
            "SFSpeechRecognizer", "SFSpeechAudioBufferRecognitionRequest", "SFSpeechURLRecognitionRequest",
            "SFSpeechRecognitionTask", "SFSpeechRecognitionResult", "SpeechAnalyzer", "SpeechTranscriber",
        ])
        add("Vision", [
            "VNImageRequestHandler", "VNRecognizeTextRequest", "VNRequest", "RecognizeTextRequest", "VNDetectBarcodesRequest",
            "VNGenerateImageFeaturePrintRequest", "VNRecognizedTextObservation", "DetectBarcodesRequest", "ImageRequestHandler",
        ])
        add("VisionKit", [
            "VNDocumentCameraViewController", "VNDocumentCameraScan", "DataScannerViewController", "ImageAnalyzer",
            "ImageAnalysisInteraction",
        ])
        add("NaturalLanguage", [
            "NLEmbedding", "NLTagger", "NLTokenizer", "NLLanguageRecognizer", "NLLanguage", "NLModel",
            "NLContextualEmbedding", "NLTag", "NLTagScheme",
        ])
        add("CoreML", [
            "MLModel", "MLMultiArray", "MLFeatureProvider", "MLModelConfiguration", "MLDictionaryFeatureProvider",
            "MLFeatureValue", "MLComputeUnits", "MLShapedArray", "MLTensor",
        ])
        add("FoundationModels", [
            "SystemLanguageModel", "LanguageModelSession", "GenerationOptions", "Generable", "Guide", "Instructions",
            "Prompt", "Transcript", "GeneratedContent", "GenerationSchema", "DynamicGenerationSchema",
        ])
        add("UserNotifications", [
            "UNUserNotificationCenter", "UNMutableNotificationContent", "UNNotificationRequest",
            "UNTimeIntervalNotificationTrigger", "UNCalendarNotificationTrigger", "UNNotificationSound",
            "UNAuthorizationOptions", "UNNotification", "UNNotificationResponse", "UNNotificationAction",
            "UNNotificationCategory", "UNNotificationSettings", "UNLocationNotificationTrigger",
        ])
        add("WidgetKit", [
            "WidgetCenter", "Timeline", "TimelineReloadPolicy", "WidgetConfiguration", "StaticConfiguration",
            "AppIntentConfiguration", "WidgetFamily", "WidgetBundle", "TimelineProvider", "TimelineEntry", "Widget",
            "AppIntentTimelineProvider", "WidgetRenderingMode", "ControlWidget",
        ])
        add("AppIntents", [
            "AppIntent", "AppShortcut", "AppShortcutsProvider", "IntentResult", "AppEnum", "AppEntity", "EntityQuery",
            "Parameter", "AppDependency", "OpenIntent", "AppIntentsPackage", "IntentDescription", "TypeDisplayRepresentation",
            "DisplayRepresentation", "AppShortcutPhrase", "IntentDialog",
        ])
        add("EventKit", ["EKEventStore", "EKEvent", "EKReminder", "EKCalendar", "EKAuthorizationStatus", "EKSpan", "EKAlarm"])
        add("Contacts", ["CNContactStore", "CNContact", "CNMutableContact", "CNContactFetchRequest"])
        add("CloudKit", ["CKContainer", "CKDatabase", "CKRecord", "CKQuery", "CKRecordZone", "CKShare", "CKSubscription", "CKError"])
        add("GameKit", ["GKLocalPlayer", "GKAccessPoint", "GKLeaderboard", "GKAchievement"])
        add("SceneKit", [
            "SCNScene", "SCNNode", "SCNView", "SCNAction", "SCNVector3", "SCNVector4", "SCNMaterial", "SCNCamera",
            "SCNLight", "SCNGeometry", "SCNSphere", "SCNBox", "SCNPlane", "SCNTransaction", "SCNMatrix4", "SCNPhysicsBody",
            "SCNHitTestResult", "SceneView",
        ])
        add("SpriteKit", [
            "SKScene", "SKNode", "SKSpriteNode", "SKAction", "SKView", "SKTexture", "SKLabelNode", "SKShapeNode",
            "SKPhysicsBody", "SKEmitterNode", "SpriteView",
        ])
        add("RealityKit", ["Entity", "ModelEntity", "AnchorEntity", "RealityView", "ARView"])
        add("ARKit", ["ARSession", "ARWorldTrackingConfiguration", "ARSCNView", "ARAnchor"])
        add("os", ["Logger", "OSLog", "OSSignposter", "OSAllocatedUnfairLock", "OSLogStore", "OSLogType"])
        add("Combine", [
            "AnyCancellable", "PassthroughSubject", "CurrentValueSubject", "Published", "Just", "Future", "AnyPublisher",
            "Cancellable", "Subscribers", "Publishers", "ObservableObject", "Deferred", "Empty", "Fail",
        ])
        add("Observation", ["Observable", "ObservationIgnored", "ObservationRegistrar"])
        add("UniformTypeIdentifiers", ["UTType"])
        add("QuartzCore", [
            "CALayer", "CAShapeLayer", "CAGradientLayer", "CABasicAnimation", "CAKeyframeAnimation", "CATransaction",
            "CADisplayLink", "CAMediaTimingFunction", "CAEmitterLayer", "CAEmitterCell", "CATransform3D",
            "CASpringAnimation", "CAMetalLayer",
        ])
        add("PDFKit", ["PDFDocument", "PDFPage", "PDFView", "PDFAnnotation", "PDFSelection", "PDFThumbnailView"])
        add("QuickLook", ["QLPreviewController", "QLThumbnailGenerator"])
        add("LocalAuthentication", ["LAContext", "LAPolicy", "LAError"])
        add("Network", ["NWPathMonitor", "NWConnection", "NWListener", "NWEndpoint", "NWParameters", "NWPath"])
        add("FirebaseCore", ["FirebaseApp", "FirebaseOptions"])
        add("ImagePlayground", ["ImagePlaygroundViewController", "ImageCreator", "ImagePlaygroundConcept", "ImagePlaygroundStyle"])
        add("Translation", ["TranslationSession", "LanguageAvailability"])
        add("TipKit", ["Tips", "TipView", "TipGroup"])
        add("BackgroundTasks", ["BGTaskScheduler", "BGAppRefreshTaskRequest", "BGProcessingTaskRequest", "BGTask", "BGAppRefreshTask"])
        add("CoreMotion", ["CMMotionManager", "CMPedometer", "CMMotionActivityManager", "CMAltimeter", "CMDeviceMotion"])
        add("CoreHaptics", ["CHHapticEngine", "CHHapticPattern", "CHHapticEvent", "CHHapticEventParameter"])
        add("MessageUI", ["MFMailComposeViewController", "MFMessageComposeViewController"])
        add("SafariServices", ["SFSafariViewController"])
        add("AuthenticationServices", [
            "ASAuthorizationController", "ASAuthorizationAppleIDProvider", "ASWebAuthenticationSession",
            "ASAuthorizationAppleIDCredential", "SignInWithAppleButton", "ASAuthorization",
        ])
        add("CoreSpotlight", ["CSSearchableItem", "CSSearchableIndex", "CSSearchableItemAttributeSet"])
        add("LinkPresentation", ["LPMetadataProvider", "LPLinkView", "LPLinkMetadata"])
        add("CoreText", ["CTFont", "CTFontDescriptor", "CTLine", "CTFramesetter"])
        add("WebKit", ["WKWebView", "WKWebViewConfiguration", "WKNavigationDelegate", "WKUserContentController", "WebView", "WebPage"])
        add("StableDiffusion", ["StableDiffusionPipeline"])
        return table
    }()
}
