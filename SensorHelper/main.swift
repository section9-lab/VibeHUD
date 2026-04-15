import Foundation

let delegate = SensorHelperDelegate()
let listener = NSXPCListener(machServiceName: "com.section9-lab.VibeHUD.SensorHelper")
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
