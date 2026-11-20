import Foundation

/// Safe 0-indexed byte FIFO over Foundation.Data that avoids Data's slice startIndex pitfalls.
struct ByteBuffer: Sendable {
    private var storage = Data()
    private var readOffset = 0

    var count: Int {
        max(0, self.storage.count - self.readOffset)
    }

    var isEmpty: Bool {
        self.count == 0
    }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        if self.readOffset >= self.storage.count {
            self.storage.removeAll(keepingCapacity: true)
            self.readOffset = 0
        }
        self.storage.append(data)
    }

    func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < self.count else { return nil }
        let idx = self.storage.startIndex + self.readOffset + offset
        return self.storage[idx]
    }

    func firstIndex(of byte: UInt8) -> Int? {
        let start = self.storage.startIndex + self.readOffset
        guard start < self.storage.endIndex,
              let found = self.storage[start..<self.storage.endIndex].firstIndex(of: byte) else {
            return nil
        }
        return found - start
    }

    func firstRange(of pattern: Data) -> Range<Int>? {
        guard !pattern.isEmpty, self.count >= pattern.count else { return nil }
        let base = self.storage.startIndex + self.readOffset
        guard let match = self.storage.range(of: pattern, options: [], in: base..<self.storage.endIndex) else {
            return nil
        }
        return (match.lowerBound - base)..<(match.upperBound - base)
    }

    func slice(_ range: Range<Int>) -> Data? {
        guard range.lowerBound >= 0, range.upperBound <= self.count, range.lowerBound <= range.upperBound else {
            return nil
        }
        let lo = self.storage.startIndex + self.readOffset + range.lowerBound
        let hi = self.storage.startIndex + self.readOffset + range.upperBound
        return self.storage.subdata(in: lo..<hi)
    }

    mutating func read(_ length: Int) -> Data? {
        guard let data = self.slice(0..<length) else { return nil }
        self.dropFirst(length)
        return data
    }

    mutating func dropFirst(_ length: Int) {
        guard length > 0 else { return }
        self.readOffset = min(self.storage.count, self.readOffset + length)
        if self.readOffset >= self.storage.count {
            self.storage.removeAll(keepingCapacity: true)
            self.readOffset = 0
        } else if self.readOffset >= 65_536 {
            self.storage.removeFirst(self.readOffset)
            self.readOffset = 0
        }
    }

    mutating func removeAll() {
        self.storage.removeAll(keepingCapacity: false)
        self.readOffset = 0
    }
}
