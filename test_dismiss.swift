import UIKit

@MainActor
func test() {
    let vc = UIViewController()
    vc.dismiss(animated: true) {
        print("Dismiss completion called")
    }
}
test()
