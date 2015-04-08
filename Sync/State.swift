/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import XCGLogger

// TODO: same comment as for SyncAuthState.swift!
private let log = XCGLogger.defaultInstance()

/*
 * This file includes types that manage intra-sync and inter-sync metadata
 * for the use of synchronizers and the state machine.
 *
 * See docs/sync.md for details on what exactly we need to persist.
 */

public struct Fetched<T: Equatable>: Equatable {
    let value: T
    let timestamp: UInt64
}

public func ==<T: Equatable>(lhs: Fetched<T>, rhs: Fetched<T>) -> Bool {
    return lhs.timestamp == rhs.timestamp &&
           lhs.value == rhs.value
}

/*
 * Persistence pref names.
 */

private let PrefVersion = "_v"
private let PrefGlobal = "global"
private let PrefGlobalTS = "globalTS"
private let PrefKeyLabel = "keyLabel"
private let PrefKeysTS = "keysTS"
private let PrefLastFetched = "lastFetched"
private let PrefClientName = "clientName"
private let PrefClientLastUpload = "clientLastUpload"



/**
 * The scratchpad consists of the following:
 *
 * 1. Cached records. We cache meta/global and crypto/keys until they change.
 * 2. Metadata like timestamps, both for cached records and for server fetches.
 * 3. User preferences -- engine enablement.
 * 4. Client record state.
 *
 * Note that the scratchpad itself is immutable, but is a class passed by reference.
 * Its mutable fields can be mutated, but you can't accidentally e.g., switch out
 * meta/global and get confused.
 *
 * TODO: the Scratchpad needs to be loaded from persistent storage, and written
 * back at certain points in the state machine (after a replayable action is taken).
 */
public class Scratchpad {
    public class Builder {
        var syncKeyBundle: KeyBundle         // For the love of god, if you change this, invalidate keys, too!
        private var global: Fetched<MetaGlobal>?
        private var keys: Fetched<Keys>?
        private var keyLabel: String
        var collectionLastFetched: [String: UInt64]
        var engineConfiguration: EngineConfiguration?
        var clientRecordLastUpload: UInt64 = 0
        var clientName: String
        var prefs: Prefs

        init(p: Scratchpad) {
            self.syncKeyBundle = p.syncKeyBundle
            self.prefs = p.prefs

            self.global = p.global

            self.keys = p.keys
            self.keyLabel = p.keyLabel

            self.collectionLastFetched = p.collectionLastFetched
            self.engineConfiguration = p.engineConfiguration
            self.clientRecordLastUpload = p.clientRecordLastUpload
            self.clientName = p.clientName
        }

        public func setKeys(keys: Fetched<Keys>?) -> Builder {
            self.keys = keys
            if let keys = keys {
                self.collectionLastFetched["crypto"] = keys.timestamp
            }
            return self
        }

        public func setGlobal(global: Fetched<MetaGlobal>?) -> Builder {
            self.global = global
            if let global = global {
                self.collectionLastFetched["meta"] = global.timestamp
            }
            return self
        }

        public func clearFetchTimestamps() -> Builder {
            self.collectionLastFetched = [:]
            return self
        }

        public func clearClientUploadTimestamp() -> Builder {
            self.clientRecordLastUpload = 0
            return self
        }

        public func build() -> Scratchpad {
            return Scratchpad(
                    b: self.syncKeyBundle,
                    m: self.global,
                    k: self.keys,
                    keyLabel: self.keyLabel,
                    fetches: self.collectionLastFetched,
                    engines: self.engineConfiguration,
                    clientUpload: self.clientRecordLastUpload,
                    clientName: self.clientName,
                    persistingTo: self.prefs
            )
        }
    }

    public func evolve() -> Scratchpad.Builder {
        return Scratchpad.Builder(p: self)
    }

    // This is never persisted.
    let syncKeyBundle: KeyBundle

    // Cached records.
    // This cached meta/global is what we use to add or remove enabled engines. See also
    // engineConfiguration, below.
    // We also use it to detect when meta/global hasn't changed -- compare timestamps.
    //
    // Note that a Scratchpad held by a Ready state will have the current server meta/global
    // here. That means we don't need to track syncIDs separately (which is how desktop and
    // Android are implemented).
    // If we don't have a meta/global, and thus we don't know syncIDs, it means we haven't
    // synced with this server before, and we'll do a fresh sync.
    let global: Fetched<MetaGlobal>?

    // We don't store your keys in Prefs. Instead, we store a key, which is seeded when
    // you first create a Scratchpad. This key is used to retrieve the real keys from
    // your Keychain.
    let keys: Fetched<Keys>?
    let keyLabel: String

    // Collection timestamps.
    var collectionLastFetched: [String: UInt64]

    // Enablement states.
    let engineConfiguration: EngineConfiguration?

    // When did we last upload our client record?
    let clientRecordLastUpload: UInt64

    // What's our client name?
    let clientName: String

    // Where do we persist when told?
    let prefs: Prefs

    class func defaultClientName() -> String {
        return "Firefox"   // TODO
    }

    init(b: KeyBundle,
         m: Fetched<MetaGlobal>?,
         k: Fetched<Keys>?,
         keyLabel: String,
         fetches: [String: UInt64],
         engines: EngineConfiguration?,
         clientUpload: UInt64,
         clientName: String,
         persistingTo prefs: Prefs
        ) {
        self.syncKeyBundle = b
        self.prefs = prefs
        self.keys = k
        self.keyLabel = keyLabel
        self.global = m
        self.collectionLastFetched = fetches
        self.clientRecordLastUpload = clientUpload
        self.clientName = clientName
    }

    // This should never be used in the end; we'll unpickle instead.
    // This should be a convenience initializer, but... Swift compiler bug?
    init(b: KeyBundle, persistingTo prefs: Prefs) {
        self.syncKeyBundle = b
        self.prefs = prefs

        self.keys = nil
        self.keyLabel = Bytes.generateGUID()
        self.global = nil
        self.collectionLastFetched = [String: UInt64]()
        self.clientRecordLastUpload = 0
        self.clientName = Scratchpad.defaultClientName()
    }

    // For convenience.
    func withGlobal(m: Fetched<MetaGlobal>?) -> Scratchpad {
        return self.evolve().setGlobal(m).build()
    }

    func freshStartWithGlobal(global: Fetched<MetaGlobal>) -> Scratchpad {
        // TODO: I *think* a new keyLabel is unnecessary.
        return self.evolve()
                   .setGlobal(global)
                   .setKeys(nil)
                   .clearFetchTimestamps()
                   .clearClientUploadTimestamp()
                   .build()
    }

    func applyEngineChoices(old: MetaGlobal?) -> (Scratchpad, MetaGlobal?) {
        log.info("Applying engine choices from inbound meta/global.")
        log.info("Old meta/global syncID: \(old?.syncID)")
        log.info("New meta/global syncID: \(self.global?.value.syncID)")
        log.info("HACK: ignoring engine choices.")

        // TODO: detect when the sets of declined or enabled engines have changed, and update
        //       our preferences and generate a new meta/global if necessary.
        return (self, nil)
    }

    private class func unpickleV1FromPrefs(prefs: Prefs, syncKeyBundle: KeyBundle) -> Scratchpad {
        let b = Scratchpad(b: syncKeyBundle, persistingTo: prefs).evolve()

        // Do this first so that the meta/global and crypto/keys unpickling can overwrite the timestamps.
        if let lastFetched: [String: AnyObject] = prefs.dictionaryForKey(PrefLastFetched) {
            b.collectionLastFetched = optFilter(mapValues(lastFetched, { ($0 as? NSNumber)?.unsignedLongLongValue }))
        }

        if let mg = prefs.stringForKey(PrefGlobal) {
            if let mgTS = prefs.unsignedLongForKey(PrefGlobalTS) {
                if let global = MetaGlobal.fromPayload(mg) {
                    b.setGlobal(Fetched(value: global, timestamp: mgTS))
                } else {
                    log.error("Malformed meta/global in prefs. Ignoring.")
                }
            } else {
                // This should never happen.
                log.error("Found global in prefs, but not globalTS!")
            }
        }

        if let keyLabel = prefs.stringForKey(PrefKeyLabel) {
            if let ckTS = prefs.unsignedLongForKey(PrefKeysTS) {
                if let keys = KeychainWrapper.objectForKey("keys." + keyLabel) as? String {
                    // We serialize as JSON.
                    let keys = Keys(payload: KeysPayload(keys))
                    if keys.valid {
                        b.setKeys(Fetched(value: keys, timestamp: ckTS))
                    } else {
                        log.error("Invalid keys extracted from Keychain. Discarding.")
                    }
                } else {
                    log.error("Found keysTS in prefs, but didn't find keys in Keychain!")
                }
            }
        }

        b.clientName = prefs.stringForKey(PrefClientName) ?? defaultClientName()
        b.clientRecordLastUpload = prefs.unsignedLongForKey(PrefClientLastUpload) ?? 0

        // TODO: engineConfiguration
        return b.build()
    }


    public class func restoreFromPrefs(prefs: Prefs, syncKeyBundle: KeyBundle) -> Scratchpad? {
        if let ver = prefs.intForKey(PrefVersion) {
            switch (ver) {
            case 1:
                return unpickleV1FromPrefs(prefs, syncKeyBundle: syncKeyBundle)
            default:
                return nil
            }
        }

        log.debug("No scratchpad found in prefs.")
        return nil
    }

    /**
     * Persist our current state to our origin prefs.
     */
    public func checkpoint() -> Scratchpad {
        return pickle(self.prefs)
    }

    func pickle(prefs: Prefs) -> Scratchpad {
        prefs.setInt(1, forKey: PrefVersion)
        if let global = global {
            prefs.setLong(global.timestamp, forKey: PrefGlobalTS)
            prefs.setString(global.value.toPayload().toString(), forKey: PrefGlobal)
        } else {
            prefs.removeObjectForKey(PrefGlobal)
            prefs.removeObjectForKey(PrefGlobalTS)
        }

        // We store the meat of your keys in the Keychain, using a random key that we persist in prefs.
        if let keys = self.keys {
            let payload = keys.value.asPayload().toString(pretty: false)
            let label = "keys." + self.keyLabel
            log.debug("Storing keys in Keychain with label \(label).")
            KeychainWrapper.setString(payload, forKey: label, accessible: KeychainWrapper.Accessible.AfterFirstUnlock)
        } else {
            log.debug("Removing keys from Keychain.")
            KeychainWrapper.removeObjectForKey(self.keyLabel)
        }

        // TODO: engineConfiguration

        prefs.setString(clientName, forKey: PrefClientName)
        prefs.setLong(clientRecordLastUpload, forKey: PrefClientLastUpload)

        // Thanks, Swift.
        let dict = mapValues(collectionLastFetched, { NSNumber(unsignedLongLong: $0) }) as NSDictionary
        prefs.setObject(dict, forKey: PrefLastFetched)

        return self
    }
}