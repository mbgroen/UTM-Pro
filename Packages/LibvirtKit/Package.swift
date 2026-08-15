// swift-tools-version:5.9
//
// Copyright © 2026 UTM Pro contributors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import PackageDescription

let package = Package(
    name: "LibvirtKit",
    platforms: [
        .macOS(.v11),
        .iOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "LibvirtKit", targets: ["LibvirtKit"]),
        .executable(name: "libvirtprobe", targets: ["libvirtprobe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.62.0"),
    ],
    targets: [
        .target(
            name: "LibvirtKit",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ]
        ),
        // Read-only command line harness for verifying the transport against a
        // real host without going through the app.
        .executableTarget(
            name: "libvirtprobe",
            dependencies: ["LibvirtKit"]
        ),
        .testTarget(
            name: "LibvirtKitTests",
            dependencies: ["LibvirtKit"]
        ),
    ]
)
