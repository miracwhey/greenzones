/**
 * Zugang zum nativen Plugin CloudKitSync.
 *
 * Im Web/Dev gibt es keinen CloudKit-Container. Der Stub bildet deshalb den
 * DEFINIERTEN Zustand „nicht verfügbar" ab: Status `couldNotDetermine`, leerer
 * Snapshot, Schreibversuche rejecten mit `noAccount`. Kein Fake-Erfolg — ein
 * Mock-Sync würde im Browser einen Zustand vorspiegeln, den es auf dem Gerät
 * nicht gibt.
 */
import { registerPlugin } from "@capacitor/core";
import type { CKAccountStatus, CloudKitSyncPlugin, CloudSnapshot } from "./definitions";

/** Fehler-Codes des Contracts (Capacitor `reject(message, code)`). */
export type CloudErrorCode = "noAccount" | "network" | "notFound" | "conflict" | "internal";

const CODES: readonly CloudErrorCode[] = ["noAccount", "network", "notFound", "conflict", "internal"];

/** Leerer Snapshot mit Status — genau die Form, die `fetchAll` ohne Konto liefert. */
export function emptySnapshot(status: CKAccountStatus): CloudSnapshot {
  return { status, userID: "", friends: [], spots: [], invitations: [] };
}

/** Fehler in der Form, die auch das native Plugin liefert (Message + `code`). */
export function cloudError(code: CloudErrorCode, message: string): Error {
  return Object.assign(new Error(message), { code });
}

/** `null` = kein Plugin-Fehler (Bug im TS-Layer), nicht stillschweigend als Netzproblem verkaufen. */
export function cloudErrorCode(error: unknown): CloudErrorCode | null {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === "string" && (CODES as readonly string[]).includes(code)
    ? (code as CloudErrorCode)
    : null;
}

/**
 * Nutzertext zu einem Plugin-Fehler — benennt Netz/Konto, nie den Nutzer.
 * Ein unbekannter Fehler bleibt ehrlich vage statt eine Ursache zu erfinden.
 */
export function cloudMessage(error: unknown): string {
  switch (cloudErrorCode(error)) {
    case "noAccount":
      return "Ohne iCloud-Konto geht das nicht raus — die App bleibt lokal nutzbar.";
    case "network":
      return "Kein Netz — es ist nichts rausgegangen. Sobald du wieder online bist, nochmal.";
    case "notFound":
      return "Der geteilte Bereich ist nicht mehr da.";
    case "conflict":
      return "Da war jemand schneller — kurz neu laden und nochmal.";
    case "internal":
      return "iCloud antwortet gerade nicht. Später nochmal probieren.";
    default:
      return "Hat nicht geklappt — nichts wurde gesendet.";
  }
}

const NO_CLOUD = "Kein CloudKit außerhalb der iOS-App.";

const web: CloudKitSyncPlugin = {
  async getAccountStatus() {
    return { status: "couldNotDetermine" };
  },
  async fetchAll() {
    return emptySnapshot("couldNotDetermine");
  },
  createFriendInvite() {
    return Promise.reject(cloudError("noAccount", NO_CLOUD));
  },
  acceptShare() {
    return Promise.reject(cloudError("noAccount", NO_CLOUD));
  },
  setProfile() {
    return Promise.reject(cloudError("noAccount", NO_CLOUD));
  },
  createSpotShare() {
    return Promise.reject(cloudError("noAccount", NO_CLOUD));
  },
  offerSpotToFriends() {
    return Promise.reject(cloudError("noAccount", NO_CLOUD));
  },
  deleteSpot() {
    return Promise.reject(cloudError("noAccount", NO_CLOUD));
  },
  saveInvitation() {
    return Promise.reject(cloudError("noAccount", NO_CLOUD));
  },
  saveReply() {
    return Promise.reject(cloudError("noAccount", NO_CLOUD));
  },
  registerSubscriptions() {
    return Promise.reject(cloudError("noAccount", NO_CLOUD));
  },
  // Kein Reject: „keine Erlaubnis" ist im Web der ehrliche Normalzustand, kein Fehler.
  async ensureNotificationPermission() {
    return { granted: false };
  },
  // Ohne Container feuert nichts — das Handle bleibt trotzdem gültig, damit der
  // Aufrufer keinen Sonderweg für „kein Listener" braucht.
  async addListener() {
    return { remove: async () => {} };
  },
};

export const CloudKitSync = registerPlugin<CloudKitSyncPlugin>("CloudKitSync", { web });

export type {
  CKAccountStatus,
  CloudFriend,
  CloudInvitation,
  CloudKitSyncPlugin,
  CloudReply,
  CloudSnapshot,
  CloudSpot,
} from "./definitions";
