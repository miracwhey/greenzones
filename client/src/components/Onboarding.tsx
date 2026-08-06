import { useState } from "react";
import { Geolocation } from "@capacitor/geolocation";
import { hapticTap } from "../lib/native";

interface Props {
  onDone: () => void;
}

export default function Onboarding({ onDone }: Props) {
  const [busy, setBusy] = useState(false);

  const allow = async () => {
    hapticTap();
    setBusy(true);
    try {
      await Geolocation.requestPermissions();
    } catch {
      // Web ohne Permissions-API oder Ablehnung — App läuft trotzdem
    }
    setBusy(false);
    onDone();
  };

  return (
    <div className="onboarding">
      <div className="ob-body">
        <div className="ob-mark" aria-hidden>
          <svg viewBox="0 0 96 96">
            <circle cx="48" cy="48" r="40" className="m1" />
            <circle cx="48" cy="48" r="26" className="m2" />
            <circle cx="48" cy="48" r="7" className="m3" />
          </svg>
        </div>
        <h1>GreenZones</h1>
        <p className="ob-sub">Wo Cannabis-Konsum draußen erlaubt ist — und wo nicht.</p>

        <div className="ob-feats">
          <div className="ob-feat">
            <div className="ob-ico ok">
              <svg viewBox="0 0 24 24">
                <path d="M4.5 12.5l5 5 10-11" />
              </svg>
            </div>
            <div>
              <b>Live-Status</b>
              <span>Ein Blick: erlaubt oder verboten an deinem Standort.</span>
            </div>
          </div>
          <div className="ob-feat">
            <div className="ob-ico ban">
              <svg viewBox="0 0 24 24">
                <circle cx="12" cy="12" r="8.5" />
                <path d="M6 6l12 12" />
              </svg>
            </div>
            <div>
              <b>Alle Schutzzonen</b>
              <span>100 m um Schulen, Kitas, Spielplätze und Sportstätten.</span>
            </div>
          </div>
          <div className="ob-feat">
            <div className="ob-ico time">
              <svg viewBox="0 0 24 24">
                <circle cx="12" cy="12" r="8.5" />
                <path d="M12 7.5V12l3 2" />
              </svg>
            </div>
            <div>
              <b>Zeitfenster</b>
              <span>Fußgängerzonen: verboten 7–20 Uhr, danach frei.</span>
            </div>
          </div>
        </div>

        <p className="ob-disclaimer">
          Orientierungshilfe auf Basis von OpenStreetMap-Daten — keine Rechtsberatung, ohne Gewähr auf
          Vollständigkeit. Maßgeblich ist §5 KCanG.
        </p>
      </div>

      <div className="ob-actions">
        <button className="ob-cta" onClick={allow} disabled={busy}>
          {busy ? "…" : "Standort freigeben"}
        </button>
        <button className="ob-skip" onClick={onDone}>
          Ohne Standort fortfahren
        </button>
      </div>
    </div>
  );
}
