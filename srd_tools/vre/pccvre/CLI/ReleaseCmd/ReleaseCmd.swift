// Copyright © 2024 Apple Inc. All Rights Reserved.

// APPLE INC.
// PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
// PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
// IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
// 1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
// 2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
// 3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
// 4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
// You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
// EA1937
// 10/02/2024

//  Copyright © 2024 Apple, Inc. All rights reserved.
//

import ArgumentParserInternal
import Foundation

extension CLI {
    struct ReleaseCmd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "release",
            abstract: "Interact with releases in the Private Cloud Compute Transparency Log.",
            subcommands: [
                ReleaseListCmd.self,
                ReleaseDumpCmd.self,
                ReleaseDownloadCmd.self,
                ReleaseVerifyCmd.self,
            ]
        )

        struct options: ParsableArguments {
            @Option(name: [.customLong("environment"), .customShort("E")],
                    help: ArgumentHelp("Select Transparency Log service environment.",
                                       visibility: .customerHidden))
            var environment = CLIDefaults.ktEnvironment

            // Debugging/test options
            @Option(name: [.customLong("ktinitendpoint")],
                    help: ArgumentHelp("KT Init Bag enpoint (req'd when --env=none).",
                                       visibility: .customerHidden),
                    transform: { try CLI.parseURL($0) })
            var ktInitEndpoint: URL?

            @Flag(name: [.customLong("tlsinsecure")],
                  help: ArgumentHelp("Disable TLS verification.", visibility: .customerHidden))
            var tlsInsecure: Bool = false

            @Flag(name: [.customLong("tracelog")],
                  help: ArgumentHelp("Enable tracing of calls to Transparency Log.",
                                     visibility: .customerHidden))
            var traceLog: Bool = false
        }

        // ReleaseInfo provides simple representation of a SW Release entry from the Transparency Log
        //   for display as json output (and logging)
        struct ReleaseInfo: Encodable {
            struct Tickets: Codable {
                var ap: String
                var code: [String] = []
                var data: [String] = []
            }

            let index: UInt64
            let dataHash: String
            let expireTime: UInt64 // unix epoch time
            let tickets: Tickets
            var createTime: UInt64? {
                guard let createTime = metadata?.timestamp else { return nil }

                return UInt64(createTime.timeIntervalSince1970)
            }
            let rawData: Data?
            var metadataJson: String? { try? metadata?.jsonString() }
            let isDownloadable: Bool
            let parsedDescription: String? // Image4 manifest properties of tickets

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(tickets, forKey: .tickets)
                try container.encode(index, forKey: .index)
                try container.encode(dataHash, forKey: .dataHash)
                try container.encode(expireTime, forKey: .expireTime)
                try container.encode(createTime, forKey: .createTime)
                try container.encode(rawData, forKey: .rawData)
                try container.encode(metadataJson, forKey: .metadata)
                try container.encode(isDownloadable, forKey: .downloadable)
                try container.encode(parsedDescription, forKey: .parsedDescription)
            }

            private enum CodingKeys: String, CodingKey {
                case tickets, index, dataHash, expireTime, createTime, rawData, metadata, downloadable, parsedDescription
            }

            private var metadata: SWReleaseMetadata? = nil

            init(_ rel: SWRelease) async {
                self.index = rel.index
                self.dataHash = rel.dataHash.hexString
                self.expireTime = rel.nodeData.expiryMs / 1000
                self.rawData = rel.rawData
                self.parsedDescription = rel.tickets?.debugDescription

                var relTickets = ReleaseInfo.Tickets(
                    ap: rel.apManifest!.description
                )

                if let cryptexManifests = rel.cryptexManifests {
                    for cM in cryptexManifests {
                        if cM.isDataOnly() {
                            relTickets.data.append(cM.description)
                        } else {
                            relTickets.code.append(cM.description)
                        }
                    }
                }

                self.tickets = relTickets
                self.metadata = rel.metadata
                self.isDownloadable = (try? await rel.metadata?.isDownloadable) ?? false
            }

            var isExpired: Bool {
                expireTime < Int(Date().timeIntervalSince1970)
            }

            var statusDescription: String {
                let isTerminalWide = Terminal.size.columns >= 98
                var result = [String]()

                if isDownloadable {
                    result.append(isTerminalWide ? "downloadable" : "D")
                }

                if isExpired {
                    result.append(isTerminalWide ? "expired" : "E")
                }

                if result.isEmpty {
                    return ""
                }

                return " (\(result.joined(separator: isTerminalWide ? ", " : ",")))"
            }

            func printableString(prefix: String = "") -> String {
                var builder = ""

                builder += prefix + "Expires: \(dateAsString(expireTime))\n"
                if let pDate = createTime {
                    builder += prefix + "Created: \(dateAsString(pDate))\n"
                } else {
                    // no metadata available
                    builder += prefix + "[not published]\n"
                }

                builder += prefix + "Tickets\n"
                builder += prefix + "      OS: \(tickets.ap)\n"
                if !tickets.code.isEmpty || !tickets.data.isEmpty {
                    builder += prefix + "    Cryptexes\n"
                    for c in tickets.code {
                        builder += prefix + "    Code: \(c)\n"
                    }
                    for c in tickets.data {
                        builder += prefix + "    Data: \(c)\n"
                    }
                }

                return builder
            }
        }
    }
}
