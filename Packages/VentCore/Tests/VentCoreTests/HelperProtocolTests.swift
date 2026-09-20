import Foundation
import Security
import Testing

import HelperProtocol

/// A malformed requirement string would make `setCodeSigningRequirement` raise
/// an Objective-C exception at connection time, which no Swift `catch` reaches.
/// Compiling both strings here turns that crash into a test failure.
private func compile(_ text: String) -> SecRequirement? {
    var requirement: SecRequirement?
    let status = SecRequirementCreateWithString(text as CFString, [], &requirement)
    return status == errSecSuccess ? requirement : nil
}

@Test("both code-signing requirements compile")
func requirementsCompile() {
    #expect(compile(HelperConstants.clientCodeSigningRequirement) != nil)
    #expect(compile(HelperConstants.helperCodeSigningRequirement) != nil)
}

@Test("the client requirement accepts the app and ventctl, the helper one only the helper")
func requirementsNameTheRightIdentifiers() {
    let client = HelperConstants.clientCodeSigningRequirement
    #expect(client.contains("identifier \"com.serenearyal.vent\""))
    #expect(client.contains("identifier \"com.serenearyal.vent.ventctl\""))
    #expect(client.hasPrefix("(identifier"))
    #expect(!client.contains("com.serenearyal.vent.helper"))

    let helper = HelperConstants.helperCodeSigningRequirement
    #expect(helper.hasPrefix("identifier \"com.serenearyal.vent.helper\""))
}

@Test("every requirement pins the team and the Apple anchor")
func requirementsPinTheTeam() {
    for text in [
        HelperConstants.clientCodeSigningRequirement,
        HelperConstants.helperCodeSigningRequirement,
    ] {
        #expect(text.contains("anchor apple generic"))
        #expect(text.contains("certificate leaf[subject.OU] = \"M9Q5YCJ5NU\""))
        // An entitlement clause would hold for a debug build and fail for a
        // release build, or the other way round.
        #expect(!text.contains("entitlement"))
    }
}

@Test("the identifiers and the daemon plist name agree")
func identifiersAgree() {
    #expect(HelperConstants.machServiceName == HelperConstants.helperBundleIdentifier)
    #expect(HelperConstants.daemonPlistName == "\(HelperConstants.helperBundleIdentifier).plist")
    #expect(HelperConstants.legacyPlistPath.hasSuffix("/\(HelperConstants.daemonPlistName)"))
    #expect(HelperConstants.legacyHelperPath.hasSuffix("/\(HelperConstants.helperBundleIdentifier)"))
}
