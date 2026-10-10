"use client";

import { useActionState } from "react";
import { FormMessage, SubmitButton, keepValues } from "@/components/ui";
import type { BarProduct } from "@/lib/types";
import { addProduct, saveProduct } from "../actions";

const toEuroInput = (c: number) => (c / 100).toFixed(2).replace(".", ",");

export function ProductRow({ product }: { product: BarProduct }) {
  const [state, action, busy] = useActionState(saveProduct.bind(null, product.id), undefined);
  return (
    <form onSubmit={keepValues(action)} className="flex flex-wrap items-center gap-2 rounded-lg border border-line p-2">
      <input name="name" defaultValue={product.name} aria-label="Nom" className="field w-40 py-1.5" required />
      <select name="category" defaultValue={product.category ?? "boissons"} aria-label="Section" className="field w-auto py-1.5">
        <option value="boissons">Boissons</option>
        <option value="snacks">Snacks</option>
      </select>
      <div className="relative">
        <input
          name="price"
          defaultValue={toEuroInput(product.price_cents)}
          aria-label="Prix en euros"
          inputMode="decimal"
          className="field w-24 py-1.5 pr-7 text-right"
          required
        />
        <span className="pointer-events-none absolute top-1/2 right-2.5 -translate-y-1/2 text-sm text-muted">€</span>
      </div>
      <label className="flex items-center gap-1.5 text-sm">
        <input type="checkbox" name="active" defaultChecked={product.active} className="h-4 w-4 accent-sky" /> En vente
      </label>
      <SubmitButton busy={busy} className="btn-secondary py-1.5" pending="…">
        Enregistrer
      </SubmitButton>
      <span className="text-xs empty:hidden">
        {state?.ok && <span className="text-ok">{state.ok}</span>}
        {state?.error && <span className="text-danger">{state.error}</span>}
      </span>
    </form>
  );
}

export function AddProductForm() {
  const [state, action, busy] = useActionState(addProduct, undefined);
  return (
    <form onSubmit={keepValues(action)} className="space-y-2">
      <p className="text-sm font-semibold text-ink">Ajouter un produit</p>
      <div className="flex flex-wrap items-center gap-2">
        <input name="name" placeholder="Ex. Jus d'orange" aria-label="Nom" className="field w-48 py-1.5" required />
        <select name="category" defaultValue="boissons" aria-label="Section" className="field w-auto py-1.5">
          <option value="boissons">Boissons</option>
          <option value="snacks">Snacks</option>
        </select>
        <div className="relative">
          <input name="price" placeholder="1,50" aria-label="Prix en euros" inputMode="decimal" className="field w-24 py-1.5 pr-7 text-right" required />
          <span className="pointer-events-none absolute top-1/2 right-2.5 -translate-y-1/2 text-sm text-muted">€</span>
        </div>
        <SubmitButton busy={busy} className="btn-primary py-1.5" pending="…">
          Ajouter
        </SubmitButton>
      </div>
      <FormMessage state={state} />
    </form>
  );
}
