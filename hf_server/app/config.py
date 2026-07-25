import os

# Model settings
MODEL_ID = "Xenova/clip-vit-base-patch32"
PROCESSOR_ID = "openai/clip-vit-base-patch32"
DEVICE = "cpu"

# ONNX options
INTRA_OP_NUM_THREADS = 4
INTER_OP_NUM_THREADS = 4

# Storage paths
IMAGES_DIR = "captured_images"

# Vector Search
SIMILARITY_THRESHOLD = 0.65

# Object Detection (YOLOv8n ONNX)
ENABLE_OBJECT_DETECTION = os.getenv("ENABLE_OBJECT_DETECTION", "false").lower() == "true"
YOLO_MODEL_ID = os.getenv("YOLO_MODEL_ID", "ultralytics/yolov8n")
YOLO_MODEL_FILENAME = os.getenv("YOLO_MODEL_FILENAME", "yolov8n.onnx")
DETECTION_CONFIDENCE_THRESHOLD = float(os.getenv("DETECTION_CONFIDENCE_THRESHOLD", "0.25"))
DETECTION_IOU_THRESHOLD = float(os.getenv("DETECTION_IOU_THRESHOLD", "0.45"))
MAX_DETECTIONS = int(os.getenv("MAX_DETECTIONS", "3"))
CROP_PADDING_RATIO = float(os.getenv("CROP_PADDING_RATIO", "0.10"))
