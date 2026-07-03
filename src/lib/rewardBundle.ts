// The shared pending-reward-bundle contract ({ metal?, items[] }) — the 0040/0041 server bundle
// shape every activity's pending rewards use. Display typing only: the server owns all bundle
// math and validation. ONE copy (extracted from explorationTypes.ts when Mining P12 needed the
// identical types); exploration and mining both import from here — never re-declare these.

export interface PendingBundleItem {
  item_id: string
  quantity: number
}

/** The pending-bundle shape ({ metal?, items[] }) — the 0040/0041 reward-bundle contract. */
export interface PendingBundle {
  metal?: number
  items?: PendingBundleItem[]
}
