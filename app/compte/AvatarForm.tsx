"use client";

import { useActionState, useRef, useState, startTransition } from "react";
import { Avatar } from "@/components/Avatar";
import { FormMessage } from "@/components/ui";
import { removeAvatar, uploadAvatar } from "./actions";

const MAX = 320; // côté du carré final, en pixels

/** Recadre au centre en carré et réduit la photo avant l'envoi (quelques dizaines de Ko). */
async function squareJpeg(file: File): Promise<Blob> {
  const bitmap = await createImageBitmap(file, { imageOrientation: "from-image" });
  const side = Math.min(bitmap.width, bitmap.height);
  const sx = (bitmap.width - side) / 2;
  const sy = (bitmap.height - side) / 2;
  const out = Math.min(MAX, side);
  const canvas = document.createElement("canvas");
  canvas.width = out;
  canvas.height = out;
  const ctx = canvas.getContext("2d")!;
  ctx.drawImage(bitmap, sx, sy, side, side, 0, 0, out, out);
  bitmap.close();
  return await new Promise((resolve, reject) =>
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("conversion"))), "image/jpeg", 0.85),
  );
}

export function AvatarForm({ url, name }: { url: string | null; name: string }) {
  const [state, upload, uploading] = useActionState(uploadAvatar, undefined);
  const [removeState, remove, removing] = useActionState(removeAvatar, undefined);
  const [preview, setPreview] = useState<string | null>(null);
  const [localError, setLocalError] = useState<string | null>(null);
  const input = useRef<HTMLInputElement>(null);
  const busy = uploading || removing;

  async function onPick(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;
    setLocalError(null);
    try {
      const blob = await squareJpeg(file);
      setPreview(URL.createObjectURL(blob));
      const fd = new FormData();
      fd.set("avatar", new File([blob], "avatar.jpg", { type: "image/jpeg" }));
      startTransition(() => upload(fd));
    } catch {
      setLocalError("Impossible de lire cette image. Essayez une photo JPEG ou PNG.");
    }
  }

  const shown = preview ?? url;
  const message = localError ? { error: localError } : (removeState ?? state);

  return (
    <div className="flex flex-col gap-4 sm:flex-row sm:items-center">
      <div className={busy ? "opacity-60" : ""}>
        <Avatar url={shown} name={name} size="lg" className="ring-4 ring-sky-soft" />
      </div>
      <div className="space-y-2">
        <input ref={input} type="file" accept="image/*" className="hidden" onChange={onPick} />
        <div className="flex flex-wrap gap-2">
          <button type="button" className="btn-primary" disabled={busy} onClick={() => input.current?.click()}>
            {uploading ? "Envoi…" : shown ? "Changer la photo" : "Ajouter une photo"}
          </button>
          {shown && (
            <button
              type="button"
              className="btn-secondary"
              disabled={busy}
              onClick={() => {
                if (!window.confirm("Supprimer votre photo de profil ?")) return;
                setPreview(null);
                startTransition(() => remove());
              }}
            >
              Supprimer
            </button>
          )}
        </div>
        <p className="text-xs text-muted">Une photo où l&apos;on voit bien votre visage. Elle est recadrée automatiquement.</p>
        <FormMessage state={message} />
      </div>
    </div>
  );
}
