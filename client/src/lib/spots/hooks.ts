/**
 * React-Anbindung der lokalen Community-Datenschicht.
 *
 * Alle Hooks laufen über useSyncExternalStore. Dessen harte Bedingung:
 * getSnapshot muss ohne Mutation dieselbe Referenz liefern — sonst rendert
 * React 19 endlos. Die Listen liefern die Stores bereits referenzstabil;
 * das ABGELEITETE Ergebnis (activeFor) wird hier pro Store-Version gecacht,
 * weil es sonst bei jedem Aufruf über `now` neu entstünde.
 */
import { useCallback, useRef, useSyncExternalStore } from "react";
import { FriendStore, InviteStore, SpotStore, friendStore, inviteStore, spotStore } from "./store";
import { SpotSync, spotSync, type SyncState } from "./sync";
import type { Friend, Invitation, Spot } from "./types";

export function useSpots(store: SpotStore = spotStore): Spot[] {
  const subscribe = useCallback((cb: () => void) => store.subscribe(cb), [store]);
  const snapshot = useCallback(() => store.getSpots(), [store]);
  return useSyncExternalStore(subscribe, snapshot, snapshot);
}

export function useFriends(store: FriendStore = friendStore): Friend[] {
  const subscribe = useCallback((cb: () => void) => store.subscribe(cb), [store]);
  const snapshot = useCallback(() => store.getFriends(), [store]);
  return useSyncExternalStore(subscribe, snapshot, snapshot);
}

/** Zustand des CloudKit-Syncs (Konto, Outbox, letzte Meldung). */
export function useSyncState(sync: SpotSync = spotSync): SyncState {
  const subscribe = useCallback((cb: () => void) => sync.subscribe(cb), [sync]);
  return useSyncExternalStore(subscribe, sync.getState, sync.getState);
}

export function useActiveInvitation(
  spotId: string | null,
  store: InviteStore = inviteStore,
): Invitation | null {
  const cache = useRef<{ version: number; spotId: string | null; value: Invitation | null } | null>(
    null,
  );
  const subscribe = useCallback((cb: () => void) => store.subscribe(cb), [store]);
  const snapshot = useCallback(() => {
    const version = store.getVersion();
    const cached = cache.current;
    if (cached && cached.version === version && cached.spotId === spotId) return cached.value;
    const value = spotId === null ? null : store.activeFor(spotId);
    cache.current = { version, spotId, value };
    return value;
  }, [store, spotId]);
  return useSyncExternalStore(subscribe, snapshot, snapshot);
}
