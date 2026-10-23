"use client";

import { useState } from "react";
import { ShopItemForm } from "./ShopItemForm";
import { SubmitButton } from "@/components/ui";
import { euros } from "@/lib/money";
import { deleteItem } from "../actions";

type ShopItem = {
  id: string;
  name: string;
  description: string | null;
  price_cents: number;
  category: string | null;
  sizes: string | null;
  colors: string | null;
  active: boolean;
  image_url: string | null;
  cost_cents?: number | null;
  track_stock?: boolean;
  low_stock_alert?: number;
};

export function ShopCatalogue({ items }: { items: ShopItem[] }) {
  const [editId, setEditId] = useState<string | null>(null);
  const [showNew, setShowNew] = useState(false);

  const grouped = items.reduce<Record<string, ShopItem[]>>((acc, item) => {
    const cat = item.category ?? "Autres";
    if (!acc[cat]) acc[cat] = [];
    acc[cat].push(item);
    return acc;
  }, {});

  return (
    <section>
      <div className="mb-3 flex items-center justify-between">
        <h2 className="text-lg font-bold tracking-tight text-navy-2">Catalogue</h2>
        {!showNew && (
          <button className="btn-primary text-sm" onClick={() => { setShowNew(true); setEditId(null); }}>
            + Ajouter un article
          </button>
        )}
      </div>

      {showNew && (
        <ShopItemForm onClose={() => setShowNew(false)} />
      )}

      {items.length === 0 && !showNew ? (
        <div className="card p-6 text-center text-muted">Aucun article. Ajoutez-en un !</div>
      ) : (
        <div className="space-y-6">
          {Object.entries(grouped).map(([cat, catItems]) => (
            <div key={cat}>
              <h3 className="mb-2 text-sm font-semibold uppercase tracking-wide text-muted">{cat}</h3>
              <div className="card overflow-hidden">
                <ul className="divide-y divide-line">
                  {catItems.map((item) => (
                    <li key={item.id}>
                      {editId === item.id ? (
                        <div className="p-4">
                          <ShopItemForm item={item} onClose={() => setEditId(null)} />
                        </div>
                      ) : (
                        <div className="flex flex-wrap items-center gap-3 px-4 py-3">
                          {/* Image thumbnail */}
                          <div className="h-12 w-12 shrink-0 overflow-hidden rounded-lg bg-paper border border-line">
                            {item.image_url ? (
                              // eslint-disable-next-line @next/next/no-img-element
                              <img src={item.image_url} alt={item.name} className="h-full w-full object-cover" />
                            ) : (
                              <div className="flex h-full items-center justify-center text-xl">🖼️</div>
                            )}
                          </div>

                          {/* Info */}
                          <div className="flex-1 min-w-0">
                            <p className="font-medium text-ink">
                              {item.name}
                              {!item.active && (
                                <span className="ml-2 rounded bg-paper px-1.5 py-0.5 text-xs text-muted border border-line">
                                  inactif
                                </span>
                              )}
                            </p>
                            <p className="text-sm font-bold text-navy-2">
                              {euros(item.price_cents)}
                              {item.cost_cents != null && (
                                <span className="ml-2 text-xs font-normal text-muted">
                                  achat {euros(item.cost_cents)} · marge {euros(item.price_cents - item.cost_cents)}
                                </span>
                              )}
                            </p>
                            <p className="text-xs text-muted">
                              {[item.sizes && `Tailles : ${item.sizes}`, item.colors && `Couleurs : ${item.colors}`]
                                .filter(Boolean)
                                .join(" · ")}
                            </p>
                          </div>

                          {/* Actions */}
                          <div className="flex gap-2">
                            <button
                              className="btn-secondary text-xs"
                              onClick={() => { setEditId(item.id); setShowNew(false); }}
                            >
                              ✏️ Modifier
                            </button>
                            <form action={deleteItem.bind(null, item.id)}>
                              <SubmitButton
                                className="text-xs text-danger hover:underline px-2 py-1"
                                pending="…"
                                confirm={`Désactiver « ${item.name} » ?`}
                              >
                                Désactiver
                              </SubmitButton>
                            </form>
                          </div>
                        </div>
                      )}
                    </li>
                  ))}
                </ul>
              </div>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}
