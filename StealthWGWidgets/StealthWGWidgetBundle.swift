import WidgetKit
import SwiftUI

@main
struct StealthWGWidgetBundle: WidgetBundle {
    var body: some Widget {
        ShieldWidget()
        StatusBoardWidget()
        QuickConnectWidget()
        if #available(iOS 18.0, *) { StealthControl() }
    }
}
