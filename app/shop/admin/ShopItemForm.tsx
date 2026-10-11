"use client";

import { useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { createBrowserSupabase } from "@/lib/supabase/client";
import { upsertItem } from "../actions";

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
};

export function ShopItemForm({
  item,
  onClose,
}: {
  item?: ShopItem | null;
  onClose?: () => void;
}) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const [imageUrl, setImageUrl] = useState<string>(item?.image_url ?? "");
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [preview, setPreview] = useState<string | null>(item?.image_url ?? null);
  const fileRef = useRef<HTMLInputElement>(null);

  async function handleImagePick(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;

    if (file.size > 5 * 1024 * 1024) {
      setUploadError("Image trop lourde (5 Mo maximum).");
      return;
    }
    if (!file.type.startsWith("image/")) {
      setUploadError("Seules les images sont acceptées.");
      return;
    }

    setUploadError(null);
    setUploading(true);

    // Local preview
    const objectUrl = URL.createObjectURL(file);
    setPreview(objectUrl);

    const supabase = createBrowserSupabase();
    const ext = file.name.split(".").pop() ?? "jpg";
    const path = `shop/${Date.now()}-${Math.random().toString(36).slice(2)}.${ext}`;

    const { error } = await supabase.storage
      .from("documents")
      .upload(path, file, { contentType: file.type, upsert: false });

    if (error) {
      setUploadError(`Envoi impossible : ${error.message}`);
      setUploading(false);
      return;
    }

    const { data } = supabase.storage.from("documents").getPublicUrl(path);
    setImageUrl(data.publicUrl);
    setUploading(false);
  }

  function removeImage() {
    setImageUrl("");
    setPreview(null);
    if (fileRef.current) fileRef.current.value = "";
  }

  async function handleSubmit(formData: FormData) {
    formData.set("image_url", imageUrl);
    startTransition(async () => {
      await upsertItem(formData);
      router.refresh();
    });
  }

  return (
    <div className="card mb-4 p-5">
      <h3 className="mb-4 font-semibold text-navy-2">
        {item ? "Modifier l'article" : "Nouvel article"}
      </h3>
      <form action={handleSubmit} className="space-y-4">
        {item && <input type="hidden" name="id" value={item.id} />}

        {/* Image */}
        <div>
          <label className="mb-1 block text-xs font-medium text-muted">Photo de l'article</label>
          <div className="flex flex-wrap items-start gap-4">
            {/* Preview */}
            <div className="relative h-32 w-32 shrink-0 overflow-hidden rounded-xl border border-line bg-paper">
              {preview ? (
                <>
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img src={preview} alt="Aperçu" className="h-full w-full object-cover" />
                  <button
                    type="button"
                    onClick={removeImage}
                    className="absolute right-1 top-1 flex h-5 w-5 items-center justify-center rounded-full bg-danger text-white text-xs leading-none shadow"
                    aria-label="Supprimer l'image"
                  >
                    ✕
                  </button>
                </>
              ) : (
                <div className="flex h-full flex-col items-center justify-center gap-1 text-muted">
                  <span className="text-3xl">🖼️</span>
                  <span className="text-xs">Aucune image</span>
                </div>
              )}
            </div>

            {/* Upload controls */}
            <div className="flex flex-col gap-2">
              <label className={`btn-secondary cursor-pointer text-sm ${uploading ? "opacity-50 pointer-events-none" : ""}`}>
                {uploading ? "Envoi…" : preview ? "Changer l'image" : "Choisir une image"}
                <input
                  ref={fileRef}
                  type="file"
                  accept="image/*"
                  className="sr-only"
                  onChange={handleImagePick}
                  disabled={uploading}
                />
              </label>
              <p className="text-xs text-muted">JPG, PNG, WebP · 5 Mo max</p>
              {uploadError && <p className="text-xs font-semibold text-danger">{uploadError}</p>}
              {uploading && <p className="text-xs text-wait">Upload en cours…</p>}
            </div>
          </div>
        </div>

        {/* Champs */}
        <div className="grid gap-3 sm:grid-cols-2">
          <div>
            <label className="mb-1 block text-xs font-medium text-muted">Nom *</label>
            <input name="name" className="field" required defaultValue={item?.name ?? ""} />
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-muted">Catégorie</label>
            <input
              name="category"
              className="field"
              defaultValue={item?.category ?? ""}
              placeholder="ex: Vêtements, Accessoires"
            />
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-muted">Prix (€) *</label>
            <input
              name="price"
              type="number"
              step="0.01"
              min="0"
              className="field"
              required
              defaultValue={item ? (item.price_cents / 100).toFixed(2) : ""}
            />
          </div>
          <div className="flex items-end">
            <label className="flex items-center gap-2 text-sm cursor-pointer">
              <input
                type="checkbox"
                name="active"
                value="true"
                defaultChecked={item ? item.active : true}
                className="accent-navy-2 h-4 w-4"
              />
              <span>Article actif (visible dans le shop)</span>
            </label>
          </div>
          <div className="sm:col-span-2">
            <label className="mb-1 block text-xs font-medium text-muted">Description</label>
            <textarea
              name="description"
              className="field"
              rows={2}
              defaultValue={item?.description ?? ""}
              placeholder="Courte description visible dans le shop"
            />
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-muted">
              Tailles disponibles
            </label>
            <input
              name="sizes"
              className="field"
              defaultValue={item?.sizes ?? ""}
              placeholder="XS,S,M,L,XL,XXL"
            />
            <p className="mt-0.5 text-xs text-muted">Séparées par des virgules</p>
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-muted">
              Couleurs disponibles
            </label>
            <input
              name="colors"
              className="field"
              defaultValue={item?.colors ?? ""}
              placeholder="Blanc,Marine,Rouge"
            />
            <p className="mt-0.5 text-xs text-muted">Séparées par des virgules</p>
          </div>
        </div>

        <div className="flex gap-3 pt-1">
          <button type="submit" disabled={isPending || uploading} className="btn-primary">
            {isPending ? "Enregistrement…" : item ? "Modifier" : "Ajouter l'article"}
          </button>
          {onClose && (
            <button type="button" onClick={onClose} className="btn-secondary">
              Annuler
            </button>
          )}
        </div>
      </form>
    </div>
  );
}
