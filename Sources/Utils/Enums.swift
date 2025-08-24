//
//  Enums.swift
//  BeAround
//
//  Created by Arthur Sousa on 20/08/25.
//

import Foundation

enum RequestType: String {
    case enter = "enter"
    case exit = "exit"
    case lost = "lost"
    case error = "error"
}

public enum TimeIntervals: Double {
    case five = 5.0
    case ten = 10.0
    case fifthteen = 15.0
    case twenty = 20.0
    case twentyFive = 25.0
}

public enum LostBeaconsStorage: Int {
    case five = 5
    case ten = 10
    case fifthteen = 15
    case twenty = 20
    case twentyFive = 25
    case thirty = 30
    case thirtyFive = 35
    case forty = 40
    case fortyFive = 45
    case fifty = 50
}
