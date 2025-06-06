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

//  Copyright © 2023 Apple Inc. All rights reserved.

private import CloudBoardCommon
import CloudBoardJobAPI
import Foundation
import os
import XPCPrivate

private enum WarmupState {
    case idle
    case waiting(Promise<Void, Error>)
    case warmupInProgress(Promise<Void, Error>?)
    case complete(Error?)
}

enum WarmupStateError: Error {
    case waitInvokedWhileAlreadyWaiting
    case waitInvokedWhileInProgressWithContinuationSet
    case warmupInvokedMoreThanOnce
    case warmupInvokedAfterComplete
    case warmupNeverCalled
    case foundWaitingAfterWarmupFinished
    case foundCompleteAfterWarmupFinished
    case foundIdleAfterWarmupFinished
}

enum JobHelperMessengerError: Error {
    case waitForWarmupCalledAfterEndJob
    case parametersReceivedTwice
    case waitForParametersCalledAfterEndJob
    case provideOutputCalledAfterEndJob
    case endJobCalledMoreThanOnce
    case tornDownBeforeParametersReceived
}

typealias JobHelperInputContinuation = AsyncStream<Data>.Continuation
typealias JobHelperTeardownContinuation = AsyncStream<Void>.Continuation
actor JobHelperMessenger {
    private static let log = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "JobHelperMessenger"
    )

    private let inputContinuation: JobHelperInputContinuation
    private let teardownContinuation: JobHelperTeardownContinuation
    private let appInstance: CloudBoardApp
    private let log: Logger

    private var warmupState: WarmupState = .idle
    private var endCalled: Bool = false
    private var metricsBuilder: CloudAppMetrics.Builder
    private var parametersReceived: Bool
    private var parametersPromise:
        Promise<ParametersData, JobHelperMessengerError> = Promise()

    private let server: CloudBoardJobAPIServerProtocol

    init(
        server: CloudBoardJobAPIServerProtocol,
        inputContinuation: JobHelperInputContinuation,
        teardownContinuation: JobHelperTeardownContinuation,
        log: os.Logger,
        appInstance: CloudBoardApp,
        metricsBuilder: CloudAppMetrics.Builder
    ) async {
        self.inputContinuation = inputContinuation
        self.teardownContinuation = teardownContinuation
        self.log = log
        self.server = server
        self.appInstance = appInstance
        self.metricsBuilder = metricsBuilder
        self.parametersReceived = false
        await self.server.set(delegate: self)
        await self.server.connect()
    }

    deinit {
        // warmup is not guaranteed to be called if we get cancelled early on so ensure that any promise that is being
        // waited on is fulfilled when this goes out of scope.
        switch self.warmupState {
        case .waiting(let promise):
            promise.fail(with: WarmupStateError.warmupNeverCalled)
        case .warmupInProgress(let promise):
            promise?.fail(with: WarmupStateError.warmupNeverCalled)
        case .idle, .complete:
            // do nothing
            ()
        }
    }

    func provideOutput(_ data: Data) async throws {
        guard self.endCalled == false else {
            throw JobHelperMessengerError.provideOutputCalledAfterEndJob
        }
        try await self.server.provideResponseChunk(data)
    }

    func waitForWarmupComplete() async throws {
        guard self.endCalled == false else {
            throw JobHelperMessengerError.waitForWarmupCalledAfterEndJob
        }

        switch self.warmupState {
        case .idle:
            let promise = Promise<Void, Error>()
            self.warmupState = .waiting(promise)
            try await Future(promise).valueWithCancellation
        case .waiting:
            throw WarmupStateError.waitInvokedWhileAlreadyWaiting
        case .warmupInProgress(let promise):
            if promise != nil {
                throw WarmupStateError.waitInvokedWhileInProgressWithContinuationSet
            }

            let promise = Promise<Void, Error>()
            self.warmupState = .warmupInProgress(promise)
            try await Future(promise).valueWithCancellation
        case .complete(let error):
            if let error {
                throw error
            }
        }
    }

    func waitForParameters() async throws -> ParametersData {
        guard self.endCalled == false else {
            throw JobHelperMessengerError.waitForParametersCalledAfterEndJob
        }
        Self.log.log("Waiting for parameters")
        defer { Self.log.log("Parameters received") }
        return try await Future(self.parametersPromise).resultWithCancellation.get()
    }

    func buildMetrics() -> CloudAppMetrics {
        return CloudAppMetrics(self.metricsBuilder, buildTime: .now)
    }

    func endJob() async throws {
        guard self.endCalled == false else {
            throw JobHelperMessengerError.endJobCalledMoreThanOnce
        }
        self.endCalled = true

        try await self.server.endJob()
    }
}

extension JobHelperMessenger: CloudBoardJobAPIServerDelegateProtocol {}

extension JobHelperMessenger: CloudBoardJobAPIClientToServerProtocol {
    func warmup(details: WarmupDetails) async throws {
        switch self.warmupState {
        case .idle:
            self.warmupState = .warmupInProgress(nil)
        case .waiting(let promise):
            self.warmupState = .warmupInProgress(promise)
        case .warmupInProgress:
            throw WarmupStateError.warmupInvokedMoreThanOnce
        case .complete:
            throw WarmupStateError.warmupInvokedAfterComplete
        }

        self.metricsBuilder.receivedJobHelperMetricDelivery(
            initialMetrics: details.initialMetrics
        )

        do {
            try await self.appInstance.warmup()
        } catch {
            switch self.warmupState {
            case .idle, .waiting:
                throw WarmupStateError.foundIdleAfterWarmupFinished
            case .warmupInProgress(let promise):
                self.warmupState = .complete(error)
                promise?.fail(with: error)
                throw error
            case .complete:
                throw WarmupStateError.foundCompleteAfterWarmupFinished
            }
        }

        switch self.warmupState {
        case .idle:
            throw WarmupStateError.foundIdleAfterWarmupFinished
        case .waiting:
            throw WarmupStateError.foundWaitingAfterWarmupFinished
        case .warmupInProgress(let promise):
            self.warmupState = .complete(nil)
            promise?.succeed()
        case .complete:
            throw WarmupStateError.foundCompleteAfterWarmupFinished
        }
    }

    func receiveParameters(parametersData: ParametersData) async throws {
        if self.parametersReceived {
            throw JobHelperMessengerError.parametersReceivedTwice
        }
        self.metricsBuilder.receivedParameters(parametersData)
        self.parametersReceived = true
        self.parametersPromise.succeed(with: parametersData)
    }

    func provideInput(_ data: Data?, isFinal: Bool) async throws {
        if let data {
            self.inputContinuation.yield(data)
        }
        if isFinal {
            self.log.debug("Received final request chunk")
            self.inputContinuation.finish()
        }
    }

    func teardown() {
        self.log.debug("Received teardown request")
        self.teardownContinuation.finish()
    }

    func cancel() {
        if self.parametersReceived == false {
            self.parametersPromise.fail(
                with:
                JobHelperMessengerError.tornDownBeforeParametersReceived
            )
        }
    }

    func helperInvocation(invocationID _: UUID) async throws {
        fatalError("Unimplemented")
    }

    func receiveHelperMessage(invocationID _: UUID, data _: Data) async throws {
        fatalError("Unimplemented")
    }

    func receiveHelperEOF(invocationID _: UUID) async throws {
        fatalError("Unimplemented")
    }
}
