import { useCallback, useEffect, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { hapticTap } from "../lib/native";
import { distanceM, formatDistanceM, type LngLat } from "../lib/geo";
import type { SearchController } from "../lib/search";
import type { OnlineState, Result, SearchState } from "../lib/search";

interface Props {
  controller: SearchController;
  /** Gewähltes Ziel — füllt das Feld und wird von außen zurückgesetzt. */
  selected: Result | null;
  userPos: LngLat | null;
  onSelect: (result: Result) => void;
  onClear: () => void;
}

/**
 * Suchfeld + Ergebnis-Overlay über dem SearchController.
 *
 * Die Sichtbarkeit des Overlays ist EIGENER State und hängt nicht an
 * Focus/Blur des Inputs: der alte Blur-Timeout hat den Tap auf eine Zeile
 * gefressen. Geschlossen wird nur durch Scrim, Auswahl oder Clear-X, und die
 * Auswahl feuert auf `pointerdown` (iOS liefert danach einen synthetischen
 * Click nach — ein zweiter Handler auf demselben Element würde doppelt zünden).
 */
export default function SearchBar({ controller, selected, userPos, onSelect, onClear }: Props) {
  const subscribe = useCallback((cb: () => void) => controller.subscribe(cb), [controller]);
  const getSnapshot = useCallback(() => controller.getState(), [controller]);
  const state = useSyncExternalStore(subscribe, getSnapshot);

  const [open, setOpen] = useState(false);
  const [text, setText] = useState("");
  const input = useRef<HTMLInputElement>(null);

  // Das Feld zeigt den gewählten Ort; endet der Ziel-Modus, ist es wieder leer.
  useEffect(() => {
    setText(selected ? selected.name : "");
  }, [selected]);

  const change = (value: string) => {
    setText(value);
    controller.setQuery(value);
    setOpen(true);
  };

  const pick = (result: Result) => {
    hapticTap();
    controller.selectResult(result);
    setText(result.name);
    setOpen(false);
    input.current?.blur();
    onSelect(result);
  };

  const clear = () => {
    hapticTap();
    controller.clear();
    setText("");
    setOpen(false);
    input.current?.blur();
    onClear();
  };

  return (
    <>
      {open && (
        <div
          className="scrim"
          data-testid="search-scrim"
          onPointerDown={() => {
            setOpen(false);
            input.current?.blur();
          }}
        />
      )}

      <div className="search-wrap">
        <div className={`search glass ${text ? "filled" : ""}`}>
          <svg className="lens" viewBox="0 0 24 24">
            <circle cx="11" cy="11" r="7" />
            <path d="m20 20-3.8-3.8" />
          </svg>
          <input
            ref={input}
            type="search"
            placeholder="Ort oder Adresse suchen"
            value={text}
            onChange={(e) => change(e.target.value)}
            onFocus={() => setOpen(true)}
            enterKeyHint="search"
            autoCorrect="off"
            autoComplete="off"
          />
          {text && (
            <button
              type="button"
              className="clear"
              aria-label="Suche zurücksetzen"
              onPointerDown={clear}
            >
              <svg viewBox="0 0 24 24">
                <path d="M6 6l12 12M18 6L6 18" />
              </svg>
            </button>
          )}
        </div>

        {open && <Panel state={state} userPos={userPos} onPick={pick} onReload={() => controller.reloadIndex()} />}
      </div>
    </>
  );
}

// ------------------------------------------------------------------- Overlay

interface PanelProps {
  state: SearchState;
  userPos: LngLat | null;
  onPick: (result: Result) => void;
  onReload: () => void;
}

function Panel({ state, userPos, onPick, onReload }: PanelProps) {
  const blocks: ReactNode[] = [];

  if (state.index.kind === "error") {
    blocks.push(
      <div className="search-note" key="index-error">
        <svg viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="8.5" />
          <path d="M12 7.5V13" />
          <circle cx="12" cy="16.2" r="0.4" fill="currentColor" stroke="none" />
        </svg>
        <span>Ortsverzeichnis nicht geladen</span>
        <button type="button" className="search-retry" onPointerDown={onReload}>
          Erneut versuchen
        </button>
      </div>,
    );
  }

  if (state.kind === "idle" && state.recents.length > 0) {
    blocks.push(
      <div className="search-sec" key="recents-sec">
        Zuletzt gesucht
      </div>,
      ...state.recents.map((r, i) => (
        <Row key={`recent-${i}`} result={r} icon={<IconClock />} onPick={onPick} />
      )),
    );
  }

  if (state.kind === "results") {
    const loadingIndex = state.index.kind === "loading";
    if (state.offline.length > 0 || loadingIndex) {
      blocks.push(
        <div className="search-sec" key="places-sec">
          Orte
        </div>,
      );
      if (state.offline.length > 0) {
        blocks.push(
          ...state.offline.map((r, i) => (
            <Row
              key={`place-${i}`}
              result={r}
              icon={<IconPlace />}
              distance={userPos ? formatDistanceM(distanceM(userPos, r)) : undefined}
              onPick={onPick}
            />
          )),
        );
      } else {
        blocks.push(
          <div className="search-note" key="places-loading">
            <div className="spinner" />
            <span>Orte laden…</span>
          </div>,
        );
      }
    }
    blocks.push(...onlineBlocks(state.online, onPick));
  }

  if (state.kind === "empty") {
    blocks.push(
      <div className="search-empty" key="empty">
        <b>Nichts gefunden</b>
        <span>
          Prüfe die Schreibweise oder such nach
          <br />
          „Straße Stadt“, z. B. „Limmerstraße Hannover“
        </span>
      </div>,
    );
  }

  if (blocks.length === 0) return null;
  return (
    <div className="search-panel glass" data-testid="search-panel">
      {blocks}
    </div>
  );
}

/** Die Online-Sektion macht jeden Zustand ihrer Quelle sichtbar. */
function onlineBlocks(online: OnlineState, onPick: (result: Result) => void): ReactNode[] {
  // `idle` heißt: Query zu kurz für die Adresssuche — kein Fehler, keine Sektion.
  if (online.kind === "idle") return [];
  if (online.kind === "results" && online.results.length === 0) return [];

  const header = (
    <div className="search-sec" key="addr-sec">
      Adressen &amp; Straßen
    </div>
  );

  if (online.kind === "loading") {
    return [
      header,
      <div className="search-note" key="addr-loading">
        <div className="spinner" />
        <span>Adressen laden…</span>
      </div>,
    ];
  }

  if (online.kind === "unavailable-offline") {
    return [
      header,
      <div className="search-note" key="addr-offline">
        <IconNoNet />
        <span>Kein Internet — Ortssuche funktioniert trotzdem</span>
      </div>,
    ];
  }

  if (online.kind === "error") {
    return [
      header,
      <div className="search-note" key="addr-error">
        <IconNoNet />
        <span>
          {online.reason === "timeout"
            ? "Adressen antworten nicht — Ortssuche funktioniert trotzdem"
            : "Adressen gerade gestört — Ortssuche funktioniert trotzdem"}
        </span>
      </div>,
    ];
  }

  return [
    header,
    ...online.results.map((r, i) => (
      <Row key={`addr-${i}`} result={r} icon={<IconAddress />} onPick={onPick} />
    )),
  ];
}

interface RowProps {
  result: Result;
  icon: ReactNode;
  distance?: string;
  onPick: (result: Result) => void;
}

function Row({ result, icon, distance, onPick }: RowProps) {
  return (
    <button
      type="button"
      className="search-row"
      data-testid="search-row"
      // NUR pointerdown — kein zusätzliches onClick auf demselben Element.
      onPointerDown={() => onPick(result)}
    >
      <span className="search-ico">{icon}</span>
      <span className="search-body">
        <b>{result.name}</b>
        <span>{result.detail}</span>
      </span>
      {distance && <span className="search-dist">{distance}</span>}
    </button>
  );
}

function IconPlace() {
  return (
    <svg viewBox="0 0 24 24">
      <path d="M12 21s-6.5-5.2-6.5-10a6.5 6.5 0 0 1 13 0c0 4.8-6.5 10-6.5 10z" />
      <circle cx="12" cy="10.6" r="2.3" />
    </svg>
  );
}

function IconAddress() {
  return (
    <svg viewBox="0 0 24 24">
      <path d="M4 20h16M6 20V6.5L12 3l6 3.5V20M10 20v-4h4v4" />
    </svg>
  );
}

function IconClock() {
  return (
    <svg viewBox="0 0 24 24">
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 7.5V12l3 2" />
    </svg>
  );
}

function IconNoNet() {
  return (
    <svg viewBox="0 0 24 24">
      <path d="M2 8.5a15 15 0 0 1 20 0M5.5 12.5a10 10 0 0 1 13 0M9 16.2a5 5 0 0 1 6 0" />
      <path d="M4 4l16 16" />
      <circle cx="12" cy="19.4" r="1" fill="currentColor" stroke="none" />
    </svg>
  );
}
