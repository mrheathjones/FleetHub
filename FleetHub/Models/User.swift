//
//  User.swift
//  FleetHub
//


import Foundation

struct User: Codable {
    let email: String
    let name: String
    let authToken: String
    let refreshToken: String?
    
    init(email: String, name: String, authToken: String = "", refreshToken: String? = nil) {
        self.email = email
        self.name = name
        self.authToken = authToken
        self.refreshToken = refreshToken
    }
}