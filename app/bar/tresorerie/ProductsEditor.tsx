"use client";

import { useActionState, useState } from "react";
import { FormMessage, SubmitButton, keepValues } from "@/components/ui";
import type { BarProduct } from "@/lib/types";
import { addProduct, saveProduct, toggleProduct } from "../actions";

const toEuroInput = (c: number) => (c / 100).toFixed(2).replace(".", ",");
const euros = (c: number) => new Intl.NumberFormat("fr-FR", { style: "currency", currency: "EUR" }).format(c / 100);

function PriceInput({ defaultValue, placeholder }: { defaultValue?: string; placeholder?: string }) {
  return (
    <div className="relative">
      <input
        name="price"
        defaultValue={defaultValue}
        placeholder={placeholder}
        aria-label="Prix en euros"
        inputMode="decimal"
        className="field w-24 py-1.5 pr-7 text-right"
        required
      />
      <span className="pointer-events-none absolute top-1/2 right-2.5 -translate-y-1/2 text-sm text-muted">€</span>
    </div>
  );
}

function SectionSelect({ defaultValue }: { defaultValue?: string }) {
  return (
    <select name="category" defaultValue={defaultValue ?? "boissons"} aria-label="Section" className="field w-auto py-1.5">
      <option value="boissons">Boissons</option>
      <option value="snacks">Snacks</option>
    </select>
  );
}

/** Un produit de la carte : affichage simple, « Modifier » ouvre la ligne, « Retirer » l'enlève de la carte. */
export function ProductRow({ product, sold }: { product: BarProduct; sold?: number }) {
  const [editing, setEditing] = useState(false);
  const [state, action, busy] = useActionState(saveProduct.bind(null, product.id), undefined);

  if (!editing) {
    return (
      <li className="flex flex-wrap items-center gap-3 px-4 py-2.5">
        <div className="min-w-0 flex-1">
          <p className={`font-semibold ${product.active ? "text-ink" : "text-muted line-through"}`}>{product.name}</p>
          {sold !== undefined && <p className="text-xs text-muted">{sold} vendu{sold > 1 ? "s" : ""} ce mois-ci</p>}
        </div>
        <span className="text-lg font-bold text-navy-2">{euros(product.price_cents)}</span>
        {state?.ok && <span className="text-xs text-ok">{state.ok}</span>}
        {state?.error && <span className="text-xs text-danger">{state.error}</span>}
        <button type="button" className="btn-secondary px-3 py-1.5 text-sm" onClick={() => setEditing(true)}>
          Modifier
        </button>
        <form action={toggleProduct.bind(null, product.id, !product.active)}>
          <SubmitButton
            className={product.active ? "px-2 py-1.5 text-sm text-danger hover:underline" : "btn-primary px-3 py-1.5 text-sm"}
            pending="…"
            confirm={product.active ? `Retirer « ${product.name} » de la carte ? (l'historique est conservé)` : undefined}
          >
            {product.active ? "Retirer" : "Remettre à la carte"}
          </SubmitButton>
        </form>
      </li>
    );
  }

  return (
    <li className="px-4 py-2.5">
      <form
        onSubmit={(e) => {
          keepValues(action)(e);
          setEditing(false);
        }}
        className="flex flex-wrap items-center gap-2"
      >
        <input name="name" defaultValue={product.name} aria-label="Nom" className="field w-44 py-1.5" required />
        <SectionSelect defaultValue={product.category} />
        <PriceInput defaultValue={toEuroInput(product.price_cents)} />
        <SubmitButton busy={busy} className="btn-primary py-1.5" pending="…">
          Enregistrer
        </SubmitButton>
        <button type="button" className="text-sm text-muted hover:underline" onClick={() => setEditing(false)}>
          Annuler
        </button>
      </form>
      {state?.error && <p className="mt-1 text-xs text-danger">{state.error}</p>}
      <p className="mt-1 text-xs text-muted">Un nouveau prix ne s&apos;applique qu&apos;aux consommations suivantes.</p>
    </li>
  );
}

export function AddProductForm() {
  const [state, action, busy] = useActionState(addProduct, undefined);
  return (
    <form onSubmit={keepValues(action)} className="space-y-2">
      <div className="flex flex-wrap items-center gap-2">
        <input name="name" placeholder="Nom (ex. Jus d'orange)" aria-label="Nom" className="field w-56 py-1.5" required />
        <SectionSelect />
        <PriceInput placeholder="1,50" />
        <SubmitButton busy={busy} className="btn-primary py-1.5" pending="…">
          + Ajouter à la carte
        </SubmitButton>
      </div>
      <FormMessage state={state} />
    </form>
  );
}
