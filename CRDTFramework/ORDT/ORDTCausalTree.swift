//
//  ORDTCausalTree.swift
//  CRDTPlayground
//
//  Created by Alexei Baboulevitch on 2018-4-21.
//  Copyright © 2018 Alexei Baboulevitch. All rights reserved.
//

import Foundation

// AB: there are methods marked internal here which are in practice public since this class isn't packaged in a
// framework; unfortunately, using a framework comes with a performance penalty, so there seems to be no way around this

// TODO: remove
extension ORDTCausalTree
{
    func incrementedClock() -> ORDTClock
    {
        let newClock = max(self.timeFunction?() ?? self.lamportTimestamp, self.lamportTimestamp + 1)
        return newClock
    }
}

// an ordered collection of atoms and their trees/yarns, for multiple sites
// TODO: DefaultInitializable only used for null start atom, should be optional or something along those lines
public final class ORDTCausalTree
    <ValueT: DefaultInitializable & CRDTValueRelationQueries & CausalTreePriority>
    : CvRDT, UsesGlobalLamport
{
    // TODO: remove these
    public init(from decoder: Decoder) throws { fatalError() }
    public func encode(to encoder: Encoder) throws { fatalError() }
    
    public typealias SiteIDT = InstancedLUID
    public typealias AtomT = CausalOperation<ValueT>
    
    public var timeFunction: ORDTTimeFunction?
    
    /////////////////
    // MARK: - Data -
    /////////////////
    
    // TODO: make owner setter, to ensure that nothing breaks
    public internal(set) var owner: SiteIDT
    
    private var atoms: [AtomT] = []
    
    ///////////////////
    // MARK: - Caches -
    ///////////////////
    
    public private(set) var lamportTimestamp: ORDTClock
    
    // these must be updated whenever the canonical data structures above are mutated; do not have to be the same on different sites
    private var weft: ORDTLocalIndexWeft = ORDTLocalIndexWeft()
    private var yarns: [AtomT] = []
    private var yarnsMap: [SiteIDT:CountableClosedRange<Int>] = [:]
    
    //////////////////////
    // MARK: - Lifecycle -
    //////////////////////
    
    // Complexity: O(N * log(N))
    public init(owner: SiteIDT, weave: inout [AtomT], timestamp: ORDTClock)
    {
        self.owner = owner
        self.atoms = weave //TODO: how is this weave copied?
        self.lamportTimestamp = timestamp
        
        generateCacheBySortingAtoms()
    }
    
    // starting from scratch
    public init(owner: SiteIDT)
    {
        self.owner = owner
        self.lamportTimestamp = 0
        
        addBaseYarn: do
        {
            // TODO: figure this out; HLC + lamport of all other ORDTs IN LOCAL DOCUMENT CONTEXT
            let lamportClock = self.timeFunction?() ?? 0
            
            let startAtomId = OperationID.init(logicalTimestamp: lamportClock, index: 0, siteID: owner.id, instanceID: owner.instanceID)
            let startAtom = AtomT.init(id: startAtomId, cause: startAtomId, value: ValueT())
            
            atoms.append(startAtom)
            updateCaches(withAtom: startAtom)
            
            assert(atomWeaveIndex(startAtomId) == WeaveIndex(startAtomId.index))
        }
    }
    
    /////////////////////
    // MARK: - Mutation -
    /////////////////////
    
    public func addAtom(withValue value: ValueT, causedBy cause: AtomT.IDT) -> (AtomT.IDT, WeaveIndex)?
    {
        let atom = AtomT.init(id: generateNextAtomId(forSite: self.owner), cause: cause, value: value)
        
        if let e = integrateAtom(atom)
        {
            return (atom.id, e)
        }
        else
        {
            return nil
        }
    }
    
    // Complexity: O(N)
    private func updateCaches(withAtom atom: AtomT)
    {
        if let existingRange = yarnsMap[atom.id.instancedSiteID]
        {
            assert(existingRange.count == atom.id.index, "adding atom out of order")
            
            let newUpperBound = existingRange.upperBound + 1
            yarns.insert(atom, at: newUpperBound)
            yarnsMap[atom.id.instancedSiteID] = existingRange.lowerBound...newUpperBound
            for (site,range) in yarnsMap
            {
                if range.lowerBound >= newUpperBound
                {
                    yarnsMap[site] = (range.lowerBound + 1)...(range.upperBound + 1)
                }
            }
            weft.update(operation: atom.id)
        }
        else
        {
            assert(atom.id.index == 0, "adding atom out of order")
            
            yarns.append(atom)
            yarnsMap[atom.id.instancedSiteID] = (yarns.count - 1)...(yarns.count - 1)
            weft.update(operation: atom.id)
        }
        
        assertCacheIntegrity()
    }
    
    // TODO: combine somehow with updateCaches
    private func generateCacheBySortingAtoms()
    {
        generateYarns: do
        {
            var yarns = self.atoms
            yarns.sort(by:
                { (a1: AtomT, a2: AtomT) -> Bool in
                    if a1.id.instancedSiteID < a2.id.instancedSiteID
                    {
                        return true
                    }
                    else if a1.id.instancedSiteID > a2.id.instancedSiteID
                    {
                        return false
                    }
                    else
                    {
                        return a1.id.index < a2.id.index
                    }
            })
            self.yarns = yarns
        }
        processYarns: do
        {
            timeMe({
                    var weft = ORDTLocalIndexWeft()
                    var yarnsMap = [SiteIDT:CountableClosedRange<Int>]()
                    
                    // PERF: we don't have to update each atom -- can simply detect change
                    for i in 0..<self.yarns.count
                    {
                        if let range = yarnsMap[self.yarns[i].id.instancedSiteID]
                        {
                            yarnsMap[self.yarns[i].id.instancedSiteID] = range.lowerBound...i
                        }
                        else
                        {
                            yarnsMap[self.yarns[i].id.instancedSiteID] = i...i
                        }
                        weft.update(operation: self.yarns[i].id)
                    }
                    
                    self.weft = weft
                    self.yarnsMap = yarnsMap
            }, "CacheGen")
        }
        
        assertCacheIntegrity()
    }
    
    // Complexity: O(1)
    private func generateNextAtomId(forSite site: SiteIDT) -> AtomT.IDT
    {
        self.lamportTimestamp = self.incrementedClock()
        
        if let lastIndex = weft.mapping[site]
        {
            return AtomT.IDT.init(logicalTimestamp: self.lamportTimestamp, index: lastIndex + 1, instancedSiteID: site)
        }
        else
        {
            return AtomT.IDT.init(logicalTimestamp: self.lamportTimestamp, index: 0, instancedSiteID: site)
        }
    }
    
    ////////////////////////
    // MARK: - Integration -
    ////////////////////////
    
    // TODO: make a protocol that atom, value, etc. conform to
    public func remapIndices(_ map: [SiteId:SiteId])
    {
        self.owner.remapIndices(map)
        
        self.atoms.remapIndices(map)
        
        self.weft.remapIndices(map)

        self.yarns.remapIndices(map)
        
        yarnsMap: do
        {
            var newYarnsMap = [SiteIDT:CountableClosedRange<Int>]()
            for v in self.yarnsMap
            {
                var newKey = v.key
                newKey.remapIndices(map)
                newYarnsMap[newKey] = v.value
            }
            self.yarnsMap = newYarnsMap
        }
        
        assertCacheIntegrity()
    }
    
    // adds atom as firstmost child of head atom, or appends to end if non-causal; lets us treat weave like an actual tree
    // Complexity: O(N)
    private func integrateAtom(_ atom: AtomT) -> WeaveIndex?
    {
        var headIndex: Int = -1
        let causeAtom = atomForId(atom.cause)
        
        if causeAtom != nil && causeAtom!.value.childless
        {
            assert(false, "appending atom to non-causal parent")
            return nil
        }
        
        if let aIndex = atomWeaveIndex(atom.cause, searchInReverse: true)
        {
            headIndex = Int(aIndex)
            
            // safety check 1
            if headIndex < atoms.count
            {
                let prevAtom = atoms[headIndex]
                assert(atom.cause == prevAtom.id, "atom is not attached to the correct parent")
            }
            
            // resolve priority ordering
            if !(atom.value.priority != 0) && (headIndex + 1) < atoms.count
            {
                let nextAtom = atoms[headIndex + 1]
                if nextAtom.cause == atom.cause && (nextAtom.value.priority != 0)
                {
                    // PERF: an unusual case: if we add a child atom to an atom that has priority children (usually
                    // deletes), then we need to find the last priority child that we can insert our new atom after;
                    // unfortunately, unlike the default case, this requires some O(N) operations
                    
                    guard let cb = causalBlock(forAtomIndexInWeave: WeaveIndex(headIndex)) else
                    {
                        assert(false, "sibling is priority but could not get causal block")
                        return nil
                    }
                    
                    for i in (cb.lowerBound + 1)...cb.upperBound
                    {
                        let a = atoms[Int(i)]
                        if a.cause == atom.cause && !(a.value.priority != 0)
                        {
                            break
                        }
                        
                        headIndex = Int(i)
                    }
                }
            }
            
            // safety check 2
            if headIndex + 1 < atoms.count
            {
                let nextAtom = atoms[headIndex + 1]
                if nextAtom.cause == atom.cause //siblings
                {
                    assert(ORDTCausalTree.atomSiblingOrder(a1: atom, a2: nextAtom), "atom is not ordered correctly")
                }
            }
        }
        else
        {
            assert(false, "could not determine location of causing atom")
            return nil
        }
        
        // no awareness recalculation, just assume it belongs in front
        atoms.insert(atom, at: headIndex + 1)
        updateCaches(withAtom: atom)
        
        return WeaveIndex(headIndex + 1)
    }
    
    public enum MergeError
    {
        case invalidAwareSiblingComparison
        case invalidUnawareSiblingComparison
        case unknownSiblingComparison
        case unknownTypeComparison
    }
    
    // we assume that indices have been correctly remapped at this point
    // we also assume that remote weave was correctly generated and isn't somehow corrupted
    // IMPORTANT: this function should only be called with a validated weave, because we do not check consistency here
    // PERF: don't need to generate entire weave + caches
    // PERF: TODO: this is currently O(W * c) (or maybe not???) and requires trusted peers; with lamport, we can do it in O(W * log(W)) and simultaneously verify + simplify our yarn algorithm
    // TODO: refactor, "basic" no longer needed since Lamport comparison is fast
    public func integrate(_ v: inout ORDTCausalTree)
    {
        typealias Insertion = (localIndex: WeaveIndex, remoteRange: CountableClosedRange<Int>)
        
        //#if DEBUG
        //    let debugCopy = self.copy() as! Weave
        //    let remoteCopy = v.copy() as! Weave
        //#endif
        
        // in order of traversal, so make sure to iterate backwards when actually mutating the weave to keep indices correct
        var insertions: [Insertion] = []
        
        var newAtoms: [AtomT] = []
        newAtoms.reserveCapacity(self.atoms.capacity)
        
        let local = weave()
        let remote = v.weave()
        let localWeft = currentWeft()
        let remoteWeft = v.currentWeft()
        
        var i = local.startIndex
        var j = remote.startIndex
        
        // instead of inserting atoms one-by-one -- an O(N) operation -- we accumulate change ranges and process
        // them later; one of these functions is called with each atom
        // TODO: get rid of this, no longer used
        var currentInsertion: Insertion?
        func insertAtom(atLocalIndex: WeaveIndex, fromRemoteIndex: WeaveIndex)
        {
            if let insertion = currentInsertion
            {
                assert(fromRemoteIndex == insertion.remoteRange.upperBound + 1, "skipped some atoms without committing")
                currentInsertion = (insertion.localIndex, insertion.remoteRange.lowerBound...Int(fromRemoteIndex))
            }
            else
            {
                currentInsertion = (atLocalIndex, Int(fromRemoteIndex)...Int(fromRemoteIndex))
            }
        }
        func commitInsertion()
        {
            if let insertion = currentInsertion
            {
                insertions.append(insertion)
                currentInsertion = nil
            }
        }
        
        func commitLocal()
        {
            //commitInsertion()
            newAtoms.append(local[i])
            i += 1
        }
        func commitRemote()
        {
            //insertAtom(atLocalIndex: WeaveIndex(i), fromRemoteIndex: WeaveIndex(j))
            newAtoms.append(remote[j])
            j += 1
        }
        func commitBoth()
        {
            //commitInsertion()
            newAtoms.append(local[i])
            i += 1
            j += 1
        }
        
        // here be the actual merge algorithm
        while (i < local.endIndex || j < remote.endIndex) {
            var mergeError: MergeError? = nil
            
            // past local bounds, so just append remote
            if i >= local.endIndex
            {
                commitRemote()
            }
                
            else if j >= remote.endIndex
            {
                commitLocal()
            }
                
            else if let comparison = try? atomArbitraryOrder(a1: local[i], a2: remote[j], basicOnly: true)
            {
                if comparison == .orderedAscending
                {
                    commitLocal()
                }
                else if comparison == .orderedDescending
                {
                    commitRemote()
                }
                else
                {
                    commitBoth()
                }
            }
                
            // assuming local weave is valid, we can just insert our local changes; relies on trust
            else if localWeft.included(remote[j].id)
            {
                // local < remote, fast forward through to the next matching sibling
                // AB: this and the below block would be more "correct" with causal blocks, but those
                // require O(weave) operations; this is functionally equivalent since we know
                // that one is aware of the other, so we have to reach the other one eventually
                // (barring corruption)
                repeat {
                    commitLocal()
                } while local[i].id != remote[j].id
            }
                
            // assuming remote weave is valid, we can just insert remote's changes; relies on trust
            else if remoteWeft.included(local[i].id)
            {
                // remote < local, fast forward through to the next matching sibling
                repeat {
                    commitRemote()
                } while local[i].id != remote[j].id
            }
                
            // testing for unaware atoms merge
            // PERF: causal block generation is O(N)... what happens if lots of concurrent changes?
            // PERF: TODO: in the case of non-sibling priority atoms conflicting with non-priority atoms, perf will be O(N),
            // can fix by precalculating weave indices for all atoms in O(N); this is only applicable in the edgiest of edge
            // cases where the number of those types of conflicts is more than one or two in a merge (super rare)
            else if
                let comparison = try? atomArbitraryOrder(a1: local[i], a2: remote[j], basicOnly: false),
                let localCausalBlock = causalBlock(forAtomIndexInWeave: WeaveIndex(i)),
                let remoteCausalBlock = v.causalBlock(forAtomIndexInWeave: WeaveIndex(j))
            {
                if comparison == .orderedAscending
                {
                    for _ in 0..<localCausalBlock.count
                    {
                        commitLocal()
                    }
                }
                else
                {
                    for _ in 0..<remoteCausalBlock.count
                    {
                        commitRemote()
                    }
                }
            }
                
            else
            {
                mergeError = .unknownTypeComparison
            }
            
            // this should never happen in theory, but in practice... let's not trust our algorithms too much
            if let error = mergeError
            {
                //#if DEBUG
                //    print("Tree 1 \(debugCopy.atomsDescription)")
                //    print("Tree 2 \(remoteCopy.atomsDescription)")
                //    print("Stopped at \(i),\(j)")
                //#endif
                
                assert(false, "atoms unequal, unaware, and not comparable -- cannot merge (\(error))")
                // TODO: return false here
            }
        }
        commitInsertion() //TODO: maybe avoid commit and just start new range when disjoint interval?
        
        process: do
        {
            //// we go in reverse to avoid having to update our indices
            //for i in (0..<insertions.count).reversed()
            //{
            //    let remoteContent = remote[insertions[i].remoteRange]
            //    atoms.insert(contentsOf: remoteContent, at: Int(insertions[i].localIndex))
            //}
            //updateCaches(afterMergeWithWeave: v)
            self.atoms = newAtoms
            generateCacheBySortingAtoms()
            self.lamportTimestamp = max(self.lamportTimestamp, v.lamportTimestamp)
        }
    }
    
    public enum ValidationError: Error
    {
        case noAtoms
        case noSites
        case causalityViolation
        case atomUnawareOfParent
        case atomUnawareOfReference
        case childlessAtomHasChildren
        case treeAtomIsUnparented
        case incorrectTreeAtomOrder
        case likelyCorruption
    }
    
    // a quick check of the invariants, so that (for example) malicious users couldn't corrupt our data
    // prerequisite: we assume that the yarn cache was successfully generated
    // assuming a reasonable (~log(N)) number of sites, O(N*log(N)) at worst, and O(N) for typical use
    public func validate() throws -> Bool
    {
        func vassert(_ b: Bool, _ e: ValidationError) throws
        {
            if !b
            {
                throw e
            }
        }

        // sanity check, since we rely on yarns being correct for the rest of this method
        try vassert(atoms.count == yarns.count, .likelyCorruption)

        let sitesCount = Int(yarnsMap.keys.count ?? 0)
        let atomsCount = atoms.count

        try vassert(atomsCount >= 1, .noAtoms)
        try vassert(sitesCount >= 1, .noSites)

        validate: do
        {
            var lastAtomChild = ContiguousArray<Int>(repeating: -1, count: atomsCount)

            var i = 0

            checkTree: do
            {
                while i < atoms.count
                {
                    let atom = atoms[i]

                    guard let a = atomYarnsIndex(atom.id) else
                    {
                        try vassert(false, .likelyCorruption); return false
                    }
                    guard let c = atomYarnsIndex(atom.cause) else
                    {
                        try vassert(false, .treeAtomIsUnparented); return false
                    }

                    let cause = yarns[Int(c)]
                    //let r = atomYarnsIndex((atom as? CRDTValueReference)?.reference ?? NullAtomId)

                    atomChecking: do
                    {
                        try vassert(!cause.value.childless, .childlessAtomHasChildren)
                    }

                    causalityProcessing: do
                    {
                        if a != 0
                        {
                            try vassert(atom.id.logicalTimestamp > yarns[Int(c)].id.logicalTimestamp, .atomUnawareOfParent)
                        }
                        //if let aR = r
                        //{
                        //    try vassert(atom.id.logicalTimestamp > yarns[Int(aR)].id.logicalTimestamp, .atomUnawareOfReference)
                        //}
                    }

                    childrenOrderChecking: if a != 0
                    {
                        if lastAtomChild[Int(c)] == -1
                        {
                            lastAtomChild[Int(c)] = Int(a)
                        }
                        else
                        {
                            let lastChild = yarns[Int(lastAtomChild[Int(c)])]

                            let order = ORDTCausalTree.atomSiblingOrder(a1: lastChild, a2: atom)

                            try vassert(order, .incorrectTreeAtomOrder)
                        }
                    }

                    i += 1
                }
            }

            return true
        }
    }
    
    private func assertCacheIntegrity()
    {
        #if DEBUG
            assert(atoms.count == yarns.count, "length mismatch between atoms and yarns")
            assert(yarnsMap.count == weft.mapping.count, "length mismatch between yarns map count and weft site count")
            
            verifyYarnMapCoverage: do
            {
                let sortedYarnMap = yarnsMap.sorted { v0,v1 -> Bool in return v0.value.upperBound < v1.value.lowerBound }
                let totalCount = sortedYarnMap.last!.value.upperBound - sortedYarnMap.first!.value.lowerBound + 1
                
                assert(totalCount == yarns.count, "yarns and yarns map count do not match")
                
                for i in 0..<sortedYarnMap.count
                {
                    if i != 0
                    {
                        assert(sortedYarnMap[i].value.lowerBound == sortedYarnMap[i - 1].value.upperBound + 1, "yarn map is not contiguous")
                    }
                }
            }
            
            var visitedArray = Array<Bool>(repeating: false, count: atoms.count)
            var visitedSites = Set<SiteIDT>()
            
            for i in 0..<atoms.count
            {
                guard let index = atomYarnsIndex(atoms[i].id) else
                {
                    assert(false, "atom not found in yarns")
                }
                
                assert(atoms[i].id == yarns[Int(index)].id, "weave atom does not match yarn atom")
                
                visitedArray[Int(index)] = true
                visitedSites.insert(atoms[i].id.instancedSiteID)
            }
            
            assert(visitedArray.reduce(true) { soFar,val in soFar && val }, "some atoms were not visited")
            assert(Set<SiteIDT>(weft.mapping.keys) == visitedSites, "weft does not have same sites as yarns")
        #endif
    }
    
    //////////////////////
    // MARK: - Iteration -
    //////////////////////
    
    // A struct that lets us treat the weave, its yarns, or any past revisions as an array. In some cases, this
    // object will generate a cache of indices in O(weave). If a weave is mutated from under a slice, the slice
    // will become invalid and will have to be revalidated. The slice must not persist past the weave lifecycle.
    // TODO: there should really be a way to initialize this with an absolute weft, while still allowing the
    // weave to use this structure internally
    // TODO: need to figure out how to treat local/absolute units in a properly functional/protocol-oriented way
    public struct AtomsSlice: RandomAccessCollection
    {
        private enum Mode
        {
            case weave(weft: ORDTLocalIndexWeft?)
            case yarn(site: SiteIDT, weft: ORDTLocalIndexWeft?)
            
            var hasWeft: Bool {
                switch self {
                case .weave(let weft):
                    return weft != nil
                case .yarn(_, let weft):
                    return weft != nil
                }
            }
            
            var requiresGeneratedIndices: Bool
            {
                switch self {
                case .weave(_):
                    return true
                case .yarn(_, _):
                    return false
                }
            }
        }
        
        private unowned let fullWeave: ORDTCausalTree
        
        private let mode: Mode
        private var generatedIndices: ContiguousArray<Int>? = nil //only used for case weave with weft
        private var startingWeft: ORDTLocalIndexWeft? = nil //used for invalidation
        
        // if a weft is present, indices will be generated
        init(withWeave weave: ORDTCausalTree, weft: ORDTLocalIndexWeft?)
        {
            self.fullWeave = weave
            self.mode = .weave(weft: weft)
            generateCache(force: true)
        }
        
        init(withWeave weave: ORDTCausalTree, site: SiteIDT, weft: ORDTLocalIndexWeft?)
        {
            self.fullWeave = weave
            self.mode = .yarn(site: site, weft: weft)
            generateCache(force: true)
        }
        
        // (re)generate indices, if needed
        // TODO: once we have absolute wefts, we can expose this for outside callers
        mutating private func generateCache(force: Bool = false)
        {
            if !force && !invalid
            {
                return
            }
            
            if case .weave(let maybeWeft) = self.mode, let weft = maybeWeft
            {
                if self.generatedIndices != nil
                {
                    self.generatedIndices!.removeAll()
                }
                else
                {
                    self.generatedIndices = ContiguousArray<Int>()
                }
                
                for i in 0..<fullWeave.atoms.count
                {
                    if weft.included(fullWeave.atoms[i].id)
                    {
                        self.generatedIndices!.append(i)
                    }
                }
            }
            else
            {
                self.generatedIndices = nil
            }
            
            self.startingWeft = fullWeave.currentWeft()
        }
        
        // we can't regenerate the indices for a struct, but we can let users know when to scrap it
        public var invalid: Bool
        {
            // AB: even though this weft does not contain 0-atom sites, we can still check for equality: if sites
            // are shifted on merge, there is no way two wefts pre- and post- merge will be equal
            if fullWeave.currentWeft() != self.startingWeft
            {
                return true
            }
            
            return false
        }
        
        public var startIndex: Int
        {
            assert(!invalid, "weave was mutated")
            
            return 0
        }
        
        public var endIndex: Int
        {
            assert(!invalid, "weave was mutated")
            
            switch self.mode
            {
            case .weave(let weft):
                if weft != nil
                {
                    return generatedIndices!.count
                }
                else
                {
                    return fullWeave.atoms.count
                }
            case .yarn(let site, let weft):
                let yarnIndex = fullWeave.currentWeft().mapping[site]
                
                if let targetWeft = weft
                {
                    let targetIndex = targetWeft.mapping[site]
                    
                    if yarnIndex == nil || targetIndex == nil
                    {
                        return 0
                    }
                    else
                    {
                        return Int(Swift.min(yarnIndex!, targetIndex!) + 1)
                    }
                }
                else
                {
                    return Int(yarnIndex != nil ? yarnIndex! + 1 : 0)
                }
            }
        }
        
        public func index(after i: Int) -> Int
        {
            assert(!invalid, "weave was mutated")
            assert(i < self.endIndex, "index not less than end index")
            
            return i + 1
        }
        
        public func index(before i: Int) -> Int
        {
            assert(!invalid, "weave was mutated")
            assert(i > self.startIndex, "index not greater than start index")
            
            return i - 1
        }
        
        public subscript(position: Int) -> AtomT
        {
            assert(!invalid, "weave was mutated")
            assert(position >= self.startIndex && position < self.endIndex, "index out of range")
            
            switch self.mode
            {
            case .weave(let weft):
                if weft != nil
                {
                    return fullWeave.atoms[generatedIndices![position]]
                }
                else
                {
                    return fullWeave.atoms[position]
                }
            case .yarn(let site, _):
                let yarnSlice = fullWeave.yarns[fullWeave.yarnsMap[site]!]
                return yarnSlice[yarnSlice.startIndex + position]
            }
        }
    }
    
    public func weave(withWeft weft: ORDTLocalIndexWeft? = nil) -> AtomsSlice
    {
        return AtomsSlice(withWeave: self, weft: weft)
    }
    
    public func yarn(forSite site: SiteIDT, withWeft weft: ORDTLocalIndexWeft? = nil) -> AtomsSlice
    {
        return AtomsSlice(withWeave: self, site: site, weft: weft)
    }
    
    //////////////////////////
    // MARK: - Basic Queries -
    //////////////////////////
    
    // Complexity: O(1)
    public func atomForId(_ atomId: AtomT.IDT) -> AtomT?
    {
        if let index = atomYarnsIndex(atomId)
        {
            return yarns[Int(index)]
        }
        else
        {
            return nil
        }
    }
    
    // Complexity: O(1)
    public func atomYarnsIndex(_ atomId: AtomT.IDT) -> AllYarnsIndex?
    {
        if atomId == NullOperationID
        {
            return nil
        }
        
        if let range = yarnsMap[atomId.instancedSiteID]
        {
            let count = (range.upperBound - range.lowerBound) + 1
            if atomId.index >= 0 && atomId.index < count
            {
                return AllYarnsIndex(range.lowerBound + Int(atomId.index))
            }
            else
            {
                return nil
            }
        }
        else
        {
            return nil
        }
    }
    
    // Complexity: O(N)
    public func atomWeaveIndex(_ atomId: AtomT.IDT, searchInReverse: Bool = false) -> WeaveIndex?
    {
        if atomId == NullOperationID
        {
            return nil
        }
        if atoms.count == 0
        {
            return nil
        }
        
        var index: Int? = nil
        
        for i in stride(from: (searchInReverse ? atoms.count - 1 : 0), through: (searchInReverse ? 0 : atoms.count - 1), by: (searchInReverse ? -1 : 1))
        {
            let atom = atoms[i]
            if atom.id == atomId
            {
                index = i
                break
            }
        }
        
        return (index != nil ? WeaveIndex(index!) : nil)
    }
    
    // Complexity: O(1)
    public func lastSiteAtomYarnsIndex(_ site: SiteIDT) -> AllYarnsIndex?
    {
        if let range = yarnsMap[site]
        {
            return AllYarnsIndex(range.upperBound)
        }
        else
        {
            return nil
        }
    }
    
    // Complexity: O(N)
    public func lastSiteAtomWeaveIndex(_ site: SiteIDT) -> WeaveIndex?
    {
        var maxIndex: Int? = nil
        for i in 0..<atoms.count
        {
            let a = atoms[i]
            if a.id.instancedSiteID == site
            {
                if let aMaxIndex = maxIndex
                {
                    if a.id.index > atoms[aMaxIndex].id.index
                    {
                        maxIndex = i
                    }
                }
                else
                {
                    maxIndex = i
                }
            }
        }
        return (maxIndex == nil ? nil : WeaveIndex(maxIndex!))
    }
    
    // Complexity: O(1)
    // NOTE: this does not include any sites in siteIndex that have zero atoms
    // TODO: this should be an an implementors' only interface
    func currentWeft() -> ORDTLocalIndexWeft
    {
        return weft
    }
    
    // Complexity: O(1)
    public func atomCount() -> Int
    {
        return atoms.count
    }
    
    // i.e., causal tree branch
    // Complexity: O(N)
    public func causalBlock(forAtomIndexInWeave index: WeaveIndex) -> CountableClosedRange<WeaveIndex>?
    {
        // 0a. an atom always appears to the left of its descendants
        // 0b. an atom always has a lower lamport timestamp than its descendants
        // 0c. causal blocks are always contiguous intervals
        //
        // 1. the first atom not in head's causal block will have a parent to the left of head
        // 2. both head and this atom are part of this parent's causal block
        // 3. therefore, head is necessarily a descendant of parent
        // 4. therefore, head necessarily has a higher timestamp than parent
        // 5. meanwhile, every atom in head's causal block will necessarily have a higher timestamp than head
        // 6. thus: the first atom whose parent has a lower timestamp than head is past the end of the causal block
        
        assert(index < atoms.count)
        
        let head = atoms[Int(index)]
        
        var range: CountableClosedRange<WeaveIndex> = WeaveIndex(index)...WeaveIndex(index)
        
        var i = Int(index) + 1
        while i < atoms.count
        {
            let nextAtom = atoms[i]
            let nextAtomParent: AtomT! = atomForId(nextAtom.cause)
            assert(nextAtomParent != nil, "could not find atom parent")
            
            if nextAtomParent.id != head.id && head.id.logicalTimestamp > nextAtomParent.id.logicalTimestamp
            {
                break
            }
            
            range = range.lowerBound...WeaveIndex(i)
            i += 1
        }
        
        assert(!head.value.childless || range.count == 1, "childless atom seems to have children")
        
        return range
    }
    
    ////////////////////////////
    // MARK: - Complex Queries -
    ////////////////////////////
    
//    public func process<T>(_ startValue: T, _ reduceClosure: ((T,ValueT)->T)) -> T
//    {
//        var sum = startValue
//        for i in 0..<atoms.count
//        {
//            // TODO: skip non-value atoms
//            sum = reduceClosure(sum, atoms[i].value)
//        }
//        return sum
//    }
    
    //////////////////
    // MARK: - Other -
    //////////////////
    
    public func superset(_ v: inout ORDTCausalTree) -> Bool
    {
        assert(false, "don't compare weaves directly -- compare through the top-level CRDT")
        return false
    }
    
    public var atomsDescription: String
    {
        var string = "[ "
        for i in 0..<atoms.count
        {
            if i != 0 {
                string += " | "
            }
            let a = atoms[i]
            string += "\(i).\(a.value),\(a.cause)->\(a.id),T\(a.id.logicalTimestamp)"
            // NEXT:
            //string += "\(i).\(a.value.atomDescription),\(a.cause)->\(a.id),T\(a.timestamp)"
        }
        string += " ]"
        return string
    }
    
    public var debugDescription: String
    {
        get
        {
            let allSites = Array(currentWeft().mapping.keys).sorted()
            var string = "["
            for i in 0..<allSites.count
            {
                if i != 0
                {
                    string += ", "
                }
                if allSites[i] == self.owner
                {
                    string += ">"
                }
                string += "\(i):\(currentWeft().mapping[allSites[i]]!)"
            }
            string += "]"
            return string
        }
    }
    
    public func sizeInBytes() -> Int
    {
        return atoms.count * MemoryLayout<AtomT>.size + MemoryLayout<SiteId>.size + MemoryLayout<CRDTCounter<YarnIndex>>.size
    }
    
    public static func ==(lhs: ORDTCausalTree, rhs: ORDTCausalTree) -> Bool
    {
        return lhs.currentWeft() == rhs.currentWeft()
    }
    
    public var hashValue: Int
    {
        return currentWeft().hashValue
    }
    
    ////////////////////////////////////
    // MARK: - Canonical Atom Ordering -
    ////////////////////////////////////
    
    public enum ComparisonError: Error
    {
        case insufficientInformation
        case unclearParentage
        case atomNotFound
    }
    
    ///
    /// **Notes:** This is a hammer for all comparison nails, but it's a bit expensive so use very carefully!
    ///
    /// **Preconditions:** Neither atom has to be in the weave, but both their parents have to be.
    ///
    /// **Complexity:** O(weave)
    ///
    public func atomArbitraryOrder(a1: AtomT, a2: AtomT, basicOnly basic: Bool) throws -> ComparisonResult
    {
        basicCases: do
        {
            if a1.id == a2.id
            {
                return ComparisonResult.orderedSame
            }
            
            rootAtom: do
            {
                if a1.cause == a1.id
                {
                    return ComparisonResult.orderedAscending
                }
                else if a2.cause == a2.id
                {
                    return ComparisonResult.orderedDescending
                }
            }
        }
        
        if basic
        {
            throw ComparisonError.insufficientInformation
        }
        
        // AB: we should very, very rarely reach this block -- basically, only if there's a merge conflict between
        // a concurrent, non-sibling priority and non-priority atom
        generalCase: do
        {
            let atomToCompare1: AtomT.IDT
            let atomToCompare2: AtomT.IDT
            
            lastCommonAncestor: do
            {
                var causeChain1: ContiguousArray<AtomT.IDT> = [a1.id]
                var causeChain2: ContiguousArray<AtomT.IDT> = [a2.id]
                
                // simple case: avoid calculating last common ancestor
                if a1.cause == a2.cause
                {
                    atomToCompare1 = a1.id
                    atomToCompare2 = a2.id
                    
                    break lastCommonAncestor
                }
                
                // this part is O(weave)
                var cause = a1.id
                while let nextCause = (cause == a1.id ? a1.cause : atomForId(cause)?.cause), nextCause != cause
                {
                    causeChain1.append(nextCause)
                    cause = nextCause
                }
                cause = a2.id
                while let nextCause = (cause == a2.id ? a2.cause : atomForId(cause)?.cause), nextCause != cause
                {
                    causeChain2.append(nextCause)
                    cause = nextCause
                }
                
                if !(causeChain1.count > 1 && causeChain2.count > 1)
                {
                    throw ComparisonError.unclearParentage
                }
                
                let causeChain1Reversed = causeChain1.reversed()
                let causeChain2Reversed = causeChain2.reversed()
                
                // this part is O(weave)
                var firstDiffIndex = 0
                while firstDiffIndex < causeChain1Reversed.count && firstDiffIndex < causeChain2Reversed.count
                {
                    let i1 = causeChain1Reversed.index(causeChain1Reversed.startIndex, offsetBy: firstDiffIndex)
                    let i2 = causeChain1Reversed.index(causeChain2Reversed.startIndex, offsetBy: firstDiffIndex)
                    if causeChain1Reversed[i1] != causeChain2Reversed[i2]
                    {
                        break
                    }
                    firstDiffIndex += 1
                }
                
                if firstDiffIndex == causeChain1Reversed.count
                {
                    return .orderedAscending //a2 includes a1
                }
                else
                {
                    let i1 = causeChain1Reversed.index(causeChain1Reversed.startIndex, offsetBy: firstDiffIndex)
                    atomToCompare1 = causeChain1Reversed[i1]
                }
                
                if firstDiffIndex == causeChain2Reversed.count
                {
                    return .orderedDescending //a1 includes a2
                }
                else
                {
                    let i2 = causeChain2Reversed.index(causeChain2Reversed.startIndex, offsetBy: firstDiffIndex)
                    atomToCompare2 = causeChain2Reversed[i2]
                }
            }
            
            guard
                let a1 = (atomToCompare1 == a1.id ? a1 : atomForId(atomToCompare1)),
                let a2 = (atomToCompare2 == a2.id ? a2 : atomForId(atomToCompare2))
                else
            {
                throw ComparisonError.atomNotFound
            }
            
            let a1a2 = ORDTCausalTree.atomSiblingOrder(a1: a1, a2: a2)
            if a1a2 { return .orderedAscending } else { return .orderedDescending }
        }
    }
    
    // a1 < a2, i.e. "to the left of"; results undefined for non-sibling atoms
    public static func atomSiblingOrder(a1: AtomT, a2: AtomT) -> Bool
    {
        precondition(a1.cause != a1.id && a2.cause != a2.id, "root atom has no siblings")
        precondition(a1.cause == a2.cause, "atoms must be siblings")
        
        if a1.id == a2.id
        {
            return false
        }
        
        // special case for priority atoms
        checkPriority: do
        {
            if (a1.value.priority != 0) && !(a2.value.priority != 0)
            {
                return true
            }
            else if !(a1.value.priority != 0) && (a2.value.priority != 0)
            {
                return false
            }
            // else, sort as default
        }
        
        defaultSort: do
        {
            if a1.id.logicalTimestamp == a2.id.logicalTimestamp
            {
                return a1.id.instancedSiteID > a2.id.instancedSiteID
            }
            else
            {
                return a1.id.logicalTimestamp > a2.id.logicalTimestamp
            }
        }
    }
}
