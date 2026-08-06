/** Öffentliche Oberfläche des Such-Kerns. */
export type {
  IndexState,
  KnownPlaceType,
  OnlineState,
  Place,
  PlacesFile,
  PlaceType,
  PhotonErrorKind,
  PhotonOutcome,
  Result,
  ResultSource,
  SearchState,
} from "./types";

export { normalize } from "./normalize";
export { DEDUPE_DISTANCE_M, dedupeAgainstOffline } from "./merge";
export {
  FALLBACK_TYPE_LABEL,
  FALLBACK_TYPE_WEIGHT,
  PlaceIndex,
  TYPE_LABEL,
  TYPE_WEIGHT,
  placeDetail,
  placeToResult,
  proximityBoost,
  typeLabel,
  typeWeight,
} from "./places";
export {
  PHOTON_BBOX,
  PHOTON_LIMIT,
  PHOTON_TIMEOUT_MS,
  PHOTON_URL,
  PhotonClient,
  classifyError,
  photonUrl,
} from "./photon";
export type { HttpTransport, PhotonClientOptions, PhotonSource } from "./photon";
export { RECENTS_KEY, RECENTS_MAX, RecentsStore } from "./recents";
export type { StorageLike } from "./recents";
export {
  DEBOUNCE_MS,
  MIN_QUERY_OFFLINE,
  MIN_QUERY_ONLINE,
  OFFLINE_LIMIT,
  SearchController,
} from "./controller";
export type { SearchControllerOptions, StateListener } from "./controller";
export {
  LocalOfflineIndex,
  PLACES_URL,
  defaultPlacesLoader,
  fetchPlaces,
  isPlacesFile,
  placesHref,
} from "./offline";
export type { OfflineIndexSource, PlacesLoader } from "./offline";
export { PlacesWorkerCore } from "./workerProtocol";
export type { PlacesFetcher, WorkerRequest, WorkerResponse } from "./workerProtocol";
export { WorkerOfflineIndex } from "./workerIndex";
