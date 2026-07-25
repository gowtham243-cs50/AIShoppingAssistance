import os
import io
import time
import datetime
from fastapi import APIRouter, File, UploadFile, Header
from fastapi.responses import FileResponse, HTMLResponse
from PIL import Image
import numpy as np

from ..config import (
    IMAGES_DIR,
    SIMILARITY_THRESHOLD,
    ENABLE_OBJECT_DETECTION,
    DETECTION_CONFIDENCE_THRESHOLD,
    DETECTION_IOU_THRESHOLD,
    MAX_DETECTIONS,
    CROP_PADDING_RATIO,
)
from ..services.detector import processor, session, get_image_embedding
from ..services.chroma import ChromaSearcher
from ..services.supabase import SupabaseQuerier

if ENABLE_OBJECT_DETECTION:
    from ..services.object_detector import detect_objects, crop_objects

router = APIRouter(tags=["Product Detection"])

@router.post("/embed")
async def get_embedding(file: UploadFile = File(...)):
    """Generate and return raw CLIP embeddings for the uploaded product image."""
    try:
        contents = await file.read()
        embedding = get_image_embedding(contents)
        return {"status": "success", "embedding": embedding}
    except Exception as e:
        return {"status": "error", "message": str(e)}

@router.post("/detect")
async def detect_item(
    file: UploadFile = File(...),
    x_chroma_token: str = Header(default=None),
    x_supabase_url: str = Header(default=None),
    x_supabase_key: str = Header(default=None)
):
    """
    Perform full end-to-end product detection:
    When ENABLE_OBJECT_DETECTION=true:
      1. Run YOLO object detection to find bounding boxes.
      2. Crop each detected object region.
      3. Generate CLIP embeddings per crop.
      4. Search ChromaDB for the best match across all crops.
    Otherwise (legacy path):
      1. Preprocess uploaded image and generate CLIP vector embeddings.
      2. Search the vector catalog in ChromaDB for similarity matches.
      3. Retrieve the matching item metadata from local catalog or Supabase DB.
    """
    start_total = time.time()
    try:
        t0 = time.time()
        contents = await file.read()
        t_read = time.time() - t0

        # -----------------------------------------------------------------
        # Object-detection path: YOLO crop -> per-crop CLIP -> best match
        # -----------------------------------------------------------------
        if ENABLE_OBJECT_DETECTION:
            t0 = time.time()
            detections = detect_objects(
                contents,
                conf_threshold=DETECTION_CONFIDENCE_THRESHOLD,
                iou_threshold=DETECTION_IOU_THRESHOLD,
                max_detections=MAX_DETECTIONS,
            )
            t_detect = time.time() - t0

            if not detections:
                print(
                    f"[detect-obj] No objects detected (detect={t_detect:.4f}s, "
                    f"total={time.time() - start_total:.4f}s)"
                )
                return {
                    "status": "success",
                    "match_found": False,
                    "reason": "No objects detected in image",
                }

            t0 = time.time()
            crops = crop_objects(contents, detections, padding_ratio=CROP_PADDING_RATIO)
            t_crop = time.time() - t0

            best_slug = None
            best_distance = float("inf")
            t_clip_total = 0.0

            for i, crop_bytes in enumerate(crops):
                t0 = time.time()
                embedding = get_image_embedding(crop_bytes)
                t_clip = time.time() - t0
                t_clip_total += t_clip

                searcher = ChromaSearcher(token=x_chroma_token)
                search_result = await searcher.search(embedding)
                if search_result is None:
                    continue

                slug, distance = search_result
                if distance <= SIMILARITY_THRESHOLD and distance < best_distance:
                    best_slug = slug
                    best_distance = distance

            if best_slug is None:
                print(
                    f"[detect-obj] No match found across {len(crops)} crops "
                    f"(detect={t_detect:.4f}s, crop={t_crop:.4f}s, "
                    f"clip={t_clip_total:.4f}s, total={time.time() - start_total:.4f}s)"
                )
                return {
                    "status": "success",
                    "match_found": False,
                    "reason": f"No match across {len(crops)} detected crops",
                }

            slug = best_slug

            if x_supabase_url and x_supabase_key:
                t0 = time.time()
                querier = SupabaseQuerier(url=x_supabase_url, key=x_supabase_key)
                product_data = await querier.get_product_by_slug(slug)
                t_supabase = time.time() - t0
            else:
                product_data = None
                t_supabase = 0.0

            print(
                f"[detect-obj] Profiling: Read={t_read:.4f}s, Detect={t_detect:.4f}s, "
                f"Crop={t_crop:.4f}s, CLIP={t_clip_total:.4f}s, "
                f"Supabase={t_supabase:.4f}s. "
                f"Total={time.time() - start_total:.4f}s"
            )

            if product_data:
                return {
                    "status": "success",
                    "match_found": True,
                    "item": {
                        "sku": product_data.get("sku"),
                        "slug": product_data.get("slug"),
                        "name": product_data.get("name"),
                        "price_rupees": float(product_data.get("price_rupees", 0.0)),
                    },
                }
            else:
                name_fallback = slug.replace("-", " ").upper()
                return {
                    "status": "success",
                    "match_found": True,
                    "item": {
                        "sku": "UNLISTED",
                        "slug": slug,
                        "name": name_fallback,
                        "price_rupees": 0.0,
                    },
                }

        # -----------------------------------------------------------------
        # Legacy whole-image CLIP path
        # -----------------------------------------------------------------
        t0 = time.time()
        image = Image.open(io.BytesIO(contents)).convert("RGB")
        image = image.resize((224, 224), Image.Resampling.BILINEAR)
        inputs = processor(images=image, return_tensors="np")
        pixel_values = inputs["pixel_values"]
        t_preprocess = time.time() - t0

        t0 = time.time()
        outputs = session.run(["image_embeds"], {"pixel_values": pixel_values})
        image_embeds = outputs[0]
        t_onnx = time.time() - t0

        norm = np.linalg.norm(image_embeds, axis=-1, keepdims=True)
        normalized_image_embeds = image_embeds / (norm + 1e-12)
        embedding = normalized_image_embeds[0].tolist()

        t0 = time.time()
        searcher = ChromaSearcher(token=x_chroma_token)
        search_result = await searcher.search(embedding)
        t_chroma = time.time() - t0

        if search_result is None:
            print(f"[detect] Finished (No ChromaDB Response) in {time.time() - start_total:.4f}s")
            return {"status": "success", "match_found": False, "reason": "No ChromaDB response"}

        slug, distance = search_result
        if distance > SIMILARITY_THRESHOLD:
            print(f"[detect] Distance {distance} exceeds threshold {SIMILARITY_THRESHOLD} for {slug} (Finished in {time.time() - start_total:.4f}s)")
            return {"status": "success", "match_found": False, "reason": f"Distance {distance} exceeds threshold {SIMILARITY_THRESHOLD}"}

        # Only query Supabase if the client requested it by sending credentials.
        # Otherwise, skip to bypass database query latency and rely on client-side local lookup.
        if x_supabase_url and x_supabase_key:
            t0 = time.time()
            querier = SupabaseQuerier(url=x_supabase_url, key=x_supabase_key)
            product_data = await querier.get_product_by_slug(slug)
            t_supabase = time.time() - t0
        else:
            product_data = None
            t_supabase = 0.0

        print(f"[detect] Profiling: Read={t_read:.4f}s, Preprocess={t_preprocess:.4f}s, ONNX={t_onnx:.4f}s, Chroma={t_chroma:.4f}s, Supabase={t_supabase:.4f}s. Total={time.time() - start_total:.4f}s")

        if product_data:
            return {
                "status": "success",
                "match_found": True,
                "item": {
                    "sku": product_data.get("sku"),
                    "slug": product_data.get("slug"),
                    "name": product_data.get("name"),
                    "price_rupees": float(product_data.get("price_rupees", 0.0))
                }
            }
        else:
            name_fallback = slug.replace('-', ' ').upper()
            return {
                "status": "success",
                "match_found": True,
                "item": {
                    "sku": "UNLISTED",
                    "slug": slug,
                    "name": name_fallback,
                    "price_rupees": 0.0
                }
            }
    except Exception as e:
        print(f"[detect] Exception: {e}")
        return {"status": "error", "message": str(e)}

@router.get("/captured_images/{filename}")
async def get_captured_image(filename: str):
    """Fetch a previously captured scan image from local disk storage."""
    filepath = os.path.join(IMAGES_DIR, filename)
    if os.path.exists(filepath):
        return FileResponse(filepath)
    return {"error": "File not found"}

@router.get("/gallery", response_class=HTMLResponse)
async def get_gallery():
    """Render a Scandinavian-modern product gallery page showcasing scanned items history."""
    files = []
    if os.path.exists(IMAGES_DIR):
        for f in os.listdir(IMAGES_DIR):
            if f.lower().endswith(('.jpg', '.jpeg', '.png')):
                fp = os.path.join(IMAGES_DIR, f)
                mtime = os.path.getmtime(fp)
                files.append((f, mtime))
    
    files.sort(key=lambda x: x[1], reverse=True)
    
    # Render Scandinavian modern light themed gallery page
    html_content = """<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Scanned Products Gallery | QLESS</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
    <style>
        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background-color: #F4F7F8;
            color: #2D3748;
            margin: 0;
            padding: 40px 24px;
            display: flex;
            flex-direction: column;
            align-items: center;
        }
        .container {
            width: 100%;
            max-width: 1100px;
        }
        header {
            margin-bottom: 40px;
            text-align: center;
        }
        h1 {
            font-size: 2.25rem;
            font-weight: 700;
            color: #1A202C;
            margin: 0 0 8px 0;
            letter-spacing: -0.025em;
        }
        p {
            color: #718096;
            font-size: 1.1rem;
            margin: 0;
        }
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
            gap: 24px;
            margin-top: 20px;
        }
        .card {
            background: #FFFFFF;
            border-radius: 18px;
            overflow: hidden;
            box-shadow: 0 4px 20px rgba(0, 0, 0, 0.03);
            border: 1px solid rgba(0, 0, 0, 0.04);
            transition: transform 0.25s cubic-bezier(0.4, 0, 0.2, 1), box-shadow 0.25s cubic-bezier(0.4, 0, 0.2, 1);
        }
        .card:hover {
            transform: translateY(-4px);
            box-shadow: 0 10px 30px rgba(0, 0, 0, 0.06);
        }
        .card-img-wrapper {
            position: relative;
            width: 100%;
            padding-top: 100%; /* 1:1 Aspect Ratio */
            background-color: #EDF2F7;
        }
        .card img {
            position: absolute;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            object-fit: cover;
        }
        .info {
            padding: 16px;
            font-size: 0.85rem;
            color: #718096;
            font-weight: 500;
            text-align: center;
            background: #FAFCFC;
            border-top: 1px solid #E2E8F0;
        }
        .empty-state {
            grid-column: 1 / -1;
            text-align: center;
            padding: 80px 20px;
            background: #FFFFFF;
            border-radius: 18px;
            border: 1px dashed #E2E8F0;
            color: #A0AEC0;
            font-size: 1.1rem;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>Product Scan History</h1>
            <p>A history of all product images captured by the AI Shopping Assistant.</p>
        </header>
        <div class="grid">
    """
    
    for f, mtime in files:
        dt = datetime.datetime.fromtimestamp(mtime).strftime('%Y-%m-%d %H:%M:%S')
        html_content += f"""
            <div class="card">
                <a href="/captured_images/{f}" target="_blank">
                    <div class="card-img-wrapper">
                        <img src="/captured_images/{f}" alt="Scan from {dt}">
                    </div>
                </a>
                <div class="info">{dt}</div>
            </div>
        """
        
    if not files:
        html_content += """
            <div class="empty-state">
                No scanned images found yet. Start scanning from the app!
            </div>
        """
        
    html_content += """
        </div>
    </div>
</body>
</html>
    """
    return html_content


