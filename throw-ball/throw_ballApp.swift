//
//  throw_ballApp.swift
//  throw-ball
//
//  Created by blueken on 2024/12/25.
//

import SwiftUI

@main
struct throw_ballApp: App {
    @State private var appModel = AppModel()
    @State private var model = ViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        
        ImmersiveSpace(id: "ImmersiveSpace") {
            ImmersiveView()
                .environment(model)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
