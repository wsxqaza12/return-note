import SwiftUI

// Swift 6.4's SDK also exposes a State macro whose plugin is absent in standalone CLT.
// Use the existing property wrapper explicitly; it also back-deploys to macOS 13.
typealias ViewState<Value> = SwiftUI.State<Value>
