import io
import numpy as np
import onnxruntime as ort
from PIL import Image
from huggingface_hub import hf_hub_download
from ..config import (
    YOLO_MODEL_ID,
    YOLO_MODEL_FILENAME,
    INTRA_OP_NUM_THREADS,
    INTER_OP_NUM_THREADS,
)

print(f"Loading YOLO detector '{YOLO_MODEL_ID}/{YOLO_MODEL_FILENAME}'...")
yolo_model_file = hf_hub_download(repo_id=YOLO_MODEL_ID, filename=YOLO_MODEL_FILENAME)

yolo_ort_options = ort.SessionOptions()
yolo_ort_options.intra_op_num_threads = INTRA_OP_NUM_THREADS
yolo_ort_options.inter_op_num_threads = INTER_OP_NUM_THREADS
yolo_session = ort.InferenceSession(
    yolo_model_file, sess_options=yolo_ort_options, providers=["CPUExecutionProvider"]
)
print("YOLO detector loaded successfully!")


def _letterbox(
    img: Image.Image, new_shape: tuple[int, int] = (640, 640)
) -> tuple[Image.Image, float, tuple[int, int]]:
    """Resize image with letterboxing (preserve aspect ratio, pad with gray)."""
    w, h = img.size
    r = min(new_shape[0] / h, new_shape[1] / w)
    new_unpad = (int(round(w * r)), int(round(h * r)))
    dw = (new_shape[1] - new_unpad[0]) / 2
    dh = (new_shape[0] - new_unpad[1]) / 2

    resized = img.resize(new_unpad, Image.Resampling.BILINEAR)

    top, bottom = int(round(dh - 0.1)), int(round(dh + 0.1))
    left, right = int(round(dw - 0.1)), int(round(dw + 0.1))
    padded = Image.new("RGB", (new_shape[1], new_shape[0]), (114, 114, 114))
    padded.paste(resized, (left, top))
    return padded, r, (dw, dh)


def _nms(boxes: np.ndarray, scores: np.ndarray, iou_threshold: float) -> np.ndarray:
    """Non-Maximum Suppression. Returns indices of kept boxes."""
    if len(boxes) == 0:
        return np.array([], dtype=int)

    order = scores.argsort()[::-1]
    keep = []

    while len(order) > 0:
        i = order[0]
        keep.append(i)
        if len(order) == 1:
            break

        xx1 = np.maximum(boxes[i, 0], boxes[order[1:], 0])
        yy1 = np.maximum(boxes[i, 1], boxes[order[1:], 1])
        xx2 = np.minimum(boxes[i, 2], boxes[order[1:], 2])
        yy2 = np.minimum(boxes[i, 3], boxes[order[1:], 3])

        inter = np.maximum(0, xx2 - xx1) * np.maximum(0, yy2 - yy1)
        area_i = (boxes[i, 2] - boxes[i, 0]) * (boxes[i, 3] - boxes[i, 1])
        area_rest = (boxes[order[1:], 2] - boxes[order[1:], 0]) * (
            boxes[order[1:], 3] - boxes[order[1:], 1]
        )
        iou = inter / (area_i + area_rest - inter + 1e-7)

        inds = np.where(iou <= iou_threshold)[0]
        order = order[inds + 1]

    return np.array(keep, dtype=int)


def _preprocess(contents: bytes) -> tuple[np.ndarray, float, tuple[int, int], tuple[int, int]]:
    """Decode image, letterbox to 640x640, return NCHW float32 tensor + metadata."""
    image = Image.open(io.BytesIO(contents)).convert("RGB")
    orig_w, orig_h = image.size

    img, ratio, (dw, dh) = _letterbox(image)
    arr = np.array(img, dtype=np.float32) / 255.0
    arr = arr.transpose(2, 0, 1)  # HWC -> CHW
    arr = np.expand_dims(arr, 0)  # add batch dim -> NCHW
    return arr, ratio, (dw, dh), (orig_w, orig_h)


def _postprocess(
    output: np.ndarray,
    conf_threshold: float,
    iou_threshold: float,
    ratio: float,
    pad: tuple[int, int],
    orig_size: tuple[int, int],
    max_detections: int,
) -> list[dict]:
    """Parse YOLO output tensor, apply NMS, return list of detections."""
    # output shape: (1, 84, 8400) -> transpose to (8400, 84)
    preds = output[0].T  # (8400, 84)

    boxes_xywh = preds[:, :4]
    class_scores = preds[:, 4:]
    max_scores = class_scores.max(axis=1)
    class_ids = class_scores.argmax(axis=1)

    # Filter by confidence
    mask = max_scores > conf_threshold
    boxes_xywh = boxes_xywh[mask]
    max_scores = max_scores[mask]
    class_ids = class_ids[mask]

    if len(max_scores) == 0:
        return []

    # Convert xywh -> xyxy
    x1 = boxes_xywh[:, 0] - boxes_xywh[:, 2] / 2
    y1 = boxes_xywh[:, 1] - boxes_xywh[:, 3] / 2
    x2 = boxes_xywh[:, 0] + boxes_xywh[:, 2] / 2
    y2 = boxes_xywh[:, 1] + boxes_xywh[:, 3] / 2
    boxes_xyxy = np.stack([x1, y1, x2, y2], axis=1)

    # NMS
    keep = _nms(boxes_xyxy, max_scores, iou_threshold)

    # Take top max_detections
    if len(keep) > max_detections:
        keep = keep[:max_detections]

    # Scale back to original image coordinates (undo letterbox padding + ratio)
    dw, dh = pad
    orig_w, orig_h = orig_size
    detections = []
    for idx in keep:
        bx1, by1, bx2, by2 = boxes_xyxy[idx]
        # Undo letterbox padding
        bx1 = (bx1 - dw) / ratio
        by1 = (by1 - dh) / ratio
        bx2 = (bx2 - dw) / ratio
        by2 = (by2 - dh) / ratio
        # Clamp to original image bounds
        bx1 = max(0, min(bx1, orig_w))
        by1 = max(0, min(by1, orig_h))
        bx2 = max(0, min(bx2, orig_w))
        by2 = max(0, min(by2, orig_h))
        detections.append(
            {
                "bbox": [float(bx1), float(by1), float(bx2), float(by2)],
                "confidence": float(max_scores[idx]),
                "class_id": int(class_ids[idx]),
            }
        )

    return detections


def detect_objects(
    contents: bytes,
    conf_threshold: float = 0.25,
    iou_threshold: float = 0.45,
    max_detections: int = 3,
) -> list[dict]:
    """Run YOLO detection on image bytes. Returns list of detections sorted by confidence."""
    pixel_values, ratio, pad, orig_size = _preprocess(contents)
    input_name = yolo_session.get_inputs()[0].name
    output_name = yolo_session.get_outputs()[0].name
    raw_output = yolo_session.run([output_name], {input_name: pixel_values})[0]
    detections = _postprocess(
        raw_output, conf_threshold, iou_threshold, ratio, pad, orig_size, max_detections
    )
    return detections


def crop_objects(
    contents: bytes, detections: list[dict], padding_ratio: float = 0.10
) -> list[bytes]:
    """Crop detected bounding box regions from the original image. Returns list of JPEG bytes."""
    image = Image.open(io.BytesIO(contents)).convert("RGB")
    orig_w, orig_h = image.size
    crops = []

    for det in detections:
        x1, y1, x2, y2 = det["bbox"]
        bw, bh = x2 - x1, y2 - y1
        pad_x, pad_y = bw * padding_ratio, bh * padding_ratio

        cx1 = max(0, int(x1 - pad_x))
        cy1 = max(0, int(y1 - pad_y))
        cx2 = min(orig_w, int(x2 + pad_x))
        cy2 = min(orig_h, int(y2 + pad_y))

        if cx2 <= cx1 or cy2 <= cy1:
            continue

        crop = image.crop((cx1, cy1, cx2, cy2))
        buf = io.BytesIO()
        crop.save(buf, format="JPEG", quality=95)
        crops.append(buf.getvalue())

    return crops
