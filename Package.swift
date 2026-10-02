// swift-tools-version:6.4
// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

internal import PackageDescription

internal let _: Package =
    Package(name: "openapi-winhttp-transport",
            products: [
              .library(name: "OpenAPIWinHTTPTransport",
                       targets: ["OpenAPIWinHTTPTransport"]),
            ],
            dependencies: [
              .package(url: "https://github.com/apple/swift-openapi-runtime",
                       from: "1.11.0"),
              .package(url: "https://github.com/apple/swift-http-types",
                       from: "1.0.0"),
            ],
            targets: [
              .target(name: "CWinHTTP"),
              .target(name: "OpenAPIWinHTTPTransport", dependencies: [
                .product(name: "OpenAPIRuntime",
                         package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                "CWinHTTP",
              ], path: "Sources/OpenAPIWinHTTP", swiftSettings: [
                .define("WORKAROUND_SWIFT_87573"),
                .enableExperimentalFeature("CheckImplementationOnly"),
                .enableExperimentalFeature("ImportMacroAliases"),
              ]),
              .testTarget(name: "OpenAPIWinHTTPTests", dependencies: [
                "OpenAPIWinHTTPTransport",
                "CWinHTTP",
                .product(name: "OpenAPIRuntime",
                         package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
              ]),
            ])
