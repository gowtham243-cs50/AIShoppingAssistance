import os
import re
import httpx
from .http_client import http_client

SLUG_STRIP_PATTERN = re.compile(r'-\d+$')

class ChromaSearcher:
    def __init__(self, token: str = None):
        self.api_key = token or os.environ.get("CHROMA_API_KEY", "")
        self.tenant = "99526d4b-48cf-4b20-896b-0947aa36d4ab"
        self.database = "QLESS2"
        self.collection_id = "8e924609-da78-4c85-87ed-95c05439f85e"
        self.url = f"https://api.trychroma.com/api/v2/tenants/{self.tenant}/databases/{self.database}/collections/{self.collection_id}/query"

    async def search(self, embedding: list[float]) -> tuple[str, float] | None:
        if not self.api_key:
            print("[ChromaSearcher] Warning: No Chroma API key found.")
            return None

        headers = {
            "x-chroma-token": self.api_key,
            "Content-Type": "application/json"
        }
        payload = {
            "query_embeddings": [embedding],
            "n_results": 1
        }

        client = http_client if http_client is not None else httpx.AsyncClient()
        close_client = http_client is None
        try:
            response = await client.post(self.url, headers=headers, json=payload, timeout=5.0)
            if response.status_code == 200:
                data = response.json()
                metadatas = data.get("metadatas", [])
                distances = data.get("distances", [])
 
                if metadatas and metadatas[0] and metadatas[0][0]:
                    item_meta = metadatas[0][0]
                    raw_name = item_meta.get("product_name", "Unknown Item")
                    slug = self._normalize_slug(str(raw_name))
                    distance = distances[0][0] if (distances and distances[0]) else 2.0
                    return slug, float(distance)
            else:
                status = response.status_code
                print(f"[ChromaSearcher] Query failed: {status} - {response.text}")
        except Exception as e:
            print(f"[ChromaSearcher] Error querying ChromaDB: {e}")
        finally:
            if close_client:
                await client.aclose()
        return None

    def _normalize_slug(self, slug: str) -> str:
        clean_slug = SLUG_STRIP_PATTERN.sub('', slug)
        mapping = {
            'roasted-almond-chocolate-bar-cadbury': 'dairy-milk-roast-almond-cadbury',
            'cadbury-dairy-milk-crispello': 'dairy-milk-crispello-cadbury',
            'fruit-and-nut-milk-chocolate-bar-cadbury': 'dairy-milk-chocolate-cadbury',
        }
        return mapping.get(clean_slug, clean_slug)
