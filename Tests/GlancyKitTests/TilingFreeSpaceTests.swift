// The empty part of a screen (FreeSpace): the maximal empty rectangle over real window frames,
// checked against a brute force, plus the gaps, the minimum size and the planner on top of it.
import CoreGraphics
import Foundation
import Testing
@testable import GlancyKit

@Suite("Tiling free space")
struct TilingFreeSpaceTests {
    let usable = CGRect(x: 0, y: 57, width: 1512, height: 892)          // the built-in, Cocoa
    let gaps = GridSpec(cols: 3, rows: 1, outerGap: 8, innerGap: 8)

    @Test func anEmptyScreenIsFreeInsideTheOuterGap() {
        #expect(FreeSpace.fillFrame(usable: usable, others: [], gaps: gaps) == usable.insetBy(dx: 8, dy: 8))
    }

    @Test func theFreeHalfKeepsTheInnerGapFromItsNeighbour() {
        let left = CGRect(x: 8, y: 65, width: 748, height: 876)
        let f = FreeSpace.fillFrame(usable: usable, others: [left], gaps: gaps)
        #expect(f == CGRect(x: 764, y: 65, width: 740, height: 876))
    }

    @Test func theLargestOfSeveralHolesWins() {
        // A tall window on the left third and a wide one along the bottom right: the top-right
        // block (≈ 1000 × 500) beats the strip under it and the sliver beside it.
        let tall = CGRect(x: 0, y: 57, width: 500, height: 892)
        let wide = CGRect(x: 500, y: 57, width: 1012, height: 380)
        let f = FreeSpace.fillFrame(usable: usable, others: [tall, wide], gaps: gaps)
        #expect(f == CGRect(x: 508, y: 445, width: 996, height: 496))
    }

    @Test func overlappingAndOffScreenWindowsCountOnlyWhereTheyCover() {
        let a = CGRect(x: -300, y: 500, width: 900, height: 600)       // half off the left edge, into the menu bar
        let b = CGRect(x: 300, y: 600, width: 200, height: 200)        // inside a
        let f = FreeSpace.largestEmptyRect(in: usable, avoiding: [a, b])
        #expect(f == CGRect(x: 600, y: 57, width: 912, height: 892))
    }

    @Test func noRoomLeftIsNil() {
        #expect(FreeSpace.fillFrame(usable: usable, others: [usable], gaps: gaps) == nil)
        // Only slivers left (a 200-pt strip on the right): below the smallest tile worth making.
        let most = CGRect(x: 0, y: 57, width: 1312, height: 892)
        #expect(FreeSpace.fillFrame(usable: usable, others: [most], gaps: gaps) == nil)
        #expect(FreeSpace.fillFrame(usable: usable, others: [most], gaps: gaps, minSize: CGSize(width: 100, height: 100)) != nil)
    }

    @Test func theUltrawideAboveWorksInItsOwnCoordinates() {
        let wide = CGRect(x: -928, y: 982, width: 3440, height: 1410)
        let left = CGRect(x: -920, y: 990, width: 1700, height: 1394)
        let f = FreeSpace.fillFrame(usable: wide, others: [left], gaps: gaps)
        #expect(f == CGRect(x: 788, y: 990, width: 1716, height: 1394))
    }

    @Test func matchesABruteForceOnRandomDesks() {
        var rng = SplitMix(seed: 42)
        for _ in 0..<200 {
            let n = Int(rng.next() % 7)
            let obstacles = (0..<n).map { _ in
                CGRect(x: CGFloat(rng.next() % 1400) - 50, y: CGFloat(rng.next() % 900),
                       width: CGFloat(80 + rng.next() % 700), height: CGFloat(60 + rng.next() % 500))
            }
            let fast = FreeSpace.largestEmptyRect(in: usable, avoiding: obstacles)
            let slow = Self.bruteForce(usable, obstacles)
            #expect(abs((fast?.width ?? 0) * (fast?.height ?? 0) - slow) < 0.5, "\(obstacles)")
            if let fast { #expect(!obstacles.contains { $0.intersection(fast).width * $0.intersection(fast).height > 0.01 }) }
        }
    }

    /// Every rectangle between two x lines and two y lines that no obstacle overlaps.
    static func bruteForce(_ bounds: CGRect, _ obstacles: [CGRect]) -> CGFloat {
        let blocks = obstacles.map { $0.intersection(bounds) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        let xs = Array(Set([bounds.minX, bounds.maxX] + blocks.flatMap { [$0.minX, $0.maxX] })).sorted()
        let ys = Array(Set([bounds.minY, bounds.maxY] + blocks.flatMap { [$0.minY, $0.maxY] })).sorted()
        var best: CGFloat = 0
        for i in xs.indices { for j in xs.indices where j > i { for k in ys.indices { for l in ys.indices where l > k {
            let r = CGRect(x: xs[i], y: ys[k], width: xs[j] - xs[i], height: ys[l] - ys[k])
            let clear = !blocks.contains { b in
                let x = r.intersection(b)
                return !x.isNull && x.width > 0 && x.height > 0
            }
            if clear { best = max(best, r.width * r.height) }
        } } } }
        return best
    }

    @Test func fitPlansTheFreeFrameAndIgnoresTheWindowItself() {
        let left = CGRect(x: 8, y: 65, width: 748, height: 876)
        let me = PlanWindow(id: 1, frame: CGRect(x: 900, y: 300, width: 300, height: 200))
        let move = ArrangePlanner.fit(me, others: [left], grid: gaps, usable: usable)
        #expect(move?.to == CGRect(x: 764, y: 65, width: 740, height: 876))
        #expect(move?.from == me.frame)
        #expect(ArrangePlanner.fit(me, others: [usable], grid: gaps, usable: usable) == nil)
    }

    @Test func menusTooltipsMinimisedAndOtherSpacesTakeNoRoom() {
        func w(_ kind: WindowKind = .tile, onScreen: Bool = true, minimized: Bool = false) -> TrackedWindow {
            TrackedWindow(id: 1, pid: 1, bundleID: nil, appName: "", title: "x", frame: usable, isMinimized: minimized,
                          isFullscreen: false, isOnScreen: onScreen, isFocused: false, kind: kind, isProvisional: false,
                          canMove: true, canResize: true, minSize: nil, zIndex: 0)
        }
        #expect(FreeSpace.occupies(w()))
        #expect(FreeSpace.occupies(w(.dialog)))
        #expect(!FreeSpace.occupies(w(.popup)))
        #expect(!FreeSpace.occupies(w(onScreen: false)))
        #expect(!FreeSpace.occupies(w(minimized: true)))
    }
}

/// A tiny deterministic generator (the tests must not depend on the run).
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
