/// Retains only the best visible search rows. Once full, a candidate that
/// cannot beat the last row costs one comparison instead of scanning every
/// retained row. Better candidates use binary insertion with stable ties.
struct BoundedSearchMatches<Match> {
    private let limit: Int
    private(set) var values: [Match] = []

    init(limit: Int, candidateCount: Int) {
        self.limit = min(max(0, limit), max(0, candidateCount))
        values.reserveCapacity(self.limit)
    }

    mutating func insert(_ match: Match, by isOrderedBefore: (Match, Match) -> Bool) {
        guard limit > 0 else { return }
        if values.count == limit,
           let last = values.last,
           !isOrderedBefore(match, last) {
            return
        }

        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if isOrderedBefore(match, values[middle]) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        values.insert(match, at: lower)
        if values.count > limit { values.removeLast() }
    }
}
