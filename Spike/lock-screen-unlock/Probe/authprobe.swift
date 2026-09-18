//
//  authprobe — stage 0's only client.
//
//  It requests `de.faceunlock.probe`, a right that guards nothing at all. No
//  file, no setting, no privilege hangs off it; granting it has no effect on
//  anything. Its entire purpose is to make SecurityAgent load our bundle and run
//  the mechanism, so the whole path — plugin loads, broker is reachable from the
//  SecurityAgent context, challenge round-trips to the app, verdict comes back,
//  deadlines and lockout behave — can be exercised with the lock screen
//  untouched.
//
//  If this cannot be made to pass, stage 1 never happens. See DESIGN.md §7.
//

import Foundation
import Security

let rightName = "de.faceunlock.probe"
let attempts = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 1) : 1

func describe(_ status: OSStatus) -> String {
    switch status {
    case errAuthorizationSuccess:          return "granted"
    case errAuthorizationDenied:           return "denied"
    case errAuthorizationCanceled:         return "cancelled"
    case errAuthorizationInteractionNotAllowed:
                                           return "interaction not allowed"
    case errAuthorizationInternal:         return "internal error"
    case -60005 /* errAuthorizationExternalizeNotAllowed */:
                                           return "externalize not allowed"
    default:
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "\(text) (\(status))"
    }
}

var authorization: AuthorizationRef?
guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
      let authorization else {
    print("Could not create an authorization reference.")
    exit(2)
}

print("Requesting \(rightName) — this right opens nothing.")
print()

var granted = 0
for attempt in 1...max(1, attempts) {
    let started = Date()
    let status: OSStatus = rightName.withCString { namePointer in
        var item = AuthorizationItem(name: namePointer, valueLength: 0, value: nil, flags: 0)
        return withUnsafeMutablePointer(to: &item) { itemPointer in
            var rights = AuthorizationRights(count: 1, items: itemPointer)
            return AuthorizationCopyRights(
                authorization, &rights, nil, [.extendRights, .interactionAllowed], nil)
        }
    }
    let elapsed = Date().timeIntervalSince(started)
    if status == errAuthorizationSuccess { granted += 1 }
    print(String(format: "  attempt %d: %@ in %.2fs", attempt, describe(status), elapsed))
}

print()
print("\(granted) of \(max(1, attempts)) granted.")
print()
print("A grant means the mechanism said yes and the whole path works.")
print("A denial is also a pass for the plumbing if the log shows the mechanism")
print("ran and declined for a stated reason:")
print("  log show --last 2m --predicate 'subsystem == \"de.faceunlock.mac\"' --info")
