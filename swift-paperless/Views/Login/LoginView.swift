//
//  LoginView.swift
//  swift-paperless
//
//  Created by Paul Gessinger on 04.08.2024.
//

import Foundation
import SwiftUI

@MainActor
protocol LoginViewProtocol: View {
    init(connectionManager: ConnectionManager, initial: Bool)
}

struct LoginView: LoginViewProtocol {
    @ObservedObject var connectionManager: ConnectionManager
    var initial = true

    var body: some View {
        switch Bundle.main.appConfiguration {
        case .AppStore, .TestFlight:
            LoginViewV1(connectionManager: connectionManager, initial: initial)
        case .Debug, .Simulator:
            LoginViewV2(connectionManager: connectionManager, initial: initial)
        }
    }
}