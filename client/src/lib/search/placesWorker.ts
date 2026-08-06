/**
 * Worker-Hülle des Ortsindex. Enthält bewusst keine Logik — die steckt in
 * `PlacesWorkerCore` und ist dadurch ohne Worker-Umgebung testbar.
 */
import { PlacesWorkerCore } from "./workerProtocol";
import type { WorkerRequest, WorkerResponse } from "./workerProtocol";

/** `self` ist hier DedicatedWorkerGlobalScope; lib.dom kennt nur das Window. */
const scope = self as unknown as {
  postMessage(message: WorkerResponse): void;
  onmessage: ((event: MessageEvent<WorkerRequest>) => void) | null;
};

const core = new PlacesWorkerCore((message) => scope.postMessage(message));

scope.onmessage = (event) => core.handle(event.data);
