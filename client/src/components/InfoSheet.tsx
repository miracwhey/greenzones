interface Props {
  open: boolean;
  onClose: () => void;
}

export default function InfoSheet({ open, onClose }: Props) {
  if (!open) return null;
  return (
    <div className="info-backdrop" onClick={onClose}>
      <div className="info glass" onClick={(e) => e.stopPropagation()}>
        <div className="grab" />
        <h2>Über GreenZones</h2>

        <section>
          <h3>Rechtsgrundlage</h3>
          <p>
            §5 Abs. 2 KCanG: Öffentlicher Konsum ist verboten in Sichtweite (100 m vom Eingangsbereich) von
            Schulen, Kinderspielplätzen, Kinder- und Jugendeinrichtungen sowie öffentlich zugänglichen
            Sportstätten — und in Fußgängerzonen zwischen 7 und 20 Uhr.
          </p>
        </section>

        <section>
          <h3>Daten</h3>
          <p>
            Zonen berechnet aus © <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>
            -Daten (ODbL). Karte: <a href="https://openfreemap.org">OpenFreeMap</a> ·{" "}
            <a href="https://openmaptiles.org">© OpenMapTiles</a>. Die Zonen werden als 100-m-Umkreis um die
            gesamte Fläche der Schutzobjekte berechnet — im Zweifel großzügiger als das Gesetz.
          </p>
        </section>

        <section>
          <h3>Kein Rechtsrat</h3>
          <p>
            Diese App ist eine Orientierungshilfe ohne Gewähr auf Richtigkeit oder Vollständigkeit.
            OpenStreetMap kennt nicht jede Einrichtung. Verantwortung bleibt bei dir.
          </p>
        </section>

        <button className="info-close" onClick={onClose}>
          Schließen
        </button>
      </div>
    </div>
  );
}
