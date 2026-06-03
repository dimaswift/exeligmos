import argparse
import json
from pathlib import Path
from urllib.parse import unquote

import torch
import torch.nn as nn
from PIL import Image
from torch.utils.data import DataLoader, Dataset, random_split
from torchvision.models import MobileNet_V3_Small_Weights, mobilenet_v3_small


DEFAULT_CLASSES = ["common", "rare", "epic", "legendary", "mythic"]


class AnimacyDataset(Dataset):
    def __init__(self, manifest_path: Path, transform):
        self.manifest_path = manifest_path
        self.root = manifest_path.parent
        self.transform = transform

        with manifest_path.open("r", encoding="utf-8") as handle:
            manifest = json.load(handle)

        self.classes = manifest.get("classes") or DEFAULT_CLASSES
        self.class_to_index = {name: index for index, name in enumerate(self.classes)}
        self.items = [
            item
            for item in manifest.get("items", [])
            if item.get("imagePath") and item.get("rarity") in self.class_to_index
        ]

        if not self.items:
            raise ValueError(f"No rarity dataset items found in {manifest_path}")

    def __len__(self):
        return len(self.items)

    def __getitem__(self, index):
        item = self.items[index]
        image_path = self.root / unquote(item["imagePath"])
        image = Image.open(image_path).convert("RGB")
        target = torch.tensor(self.class_to_index[item["rarity"]], dtype=torch.long)
        return self.transform(image), target


def build_model(class_count: int):
    weights = MobileNet_V3_Small_Weights.IMAGENET1K_V1
    model = mobilenet_v3_small(weights=weights)
    in_features = model.classifier[-1].in_features
    model.classifier[-1] = nn.Linear(in_features, class_count)
    return model, weights.transforms()


def train(args):
    device = torch.device(args.device if args.device else ("cuda" if torch.cuda.is_available() else "cpu"))
    probe_dataset = AnimacyDataset(args.manifest, transform=lambda image: image)
    model, transform = build_model(len(probe_dataset.classes))
    dataset = AnimacyDataset(args.manifest, transform)
    model.to(device)

    val_count = max(1, int(len(dataset) * args.val_fraction)) if len(dataset) > 4 else 0
    train_count = len(dataset) - val_count
    train_dataset, val_dataset = random_split(
        dataset,
        [train_count, val_count],
        generator=torch.Generator().manual_seed(args.seed),
    )

    train_loader = DataLoader(train_dataset, batch_size=args.batch_size, shuffle=True, num_workers=args.workers)
    val_loader = DataLoader(val_dataset, batch_size=args.batch_size, shuffle=False, num_workers=args.workers) if val_count else None

    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=args.weight_decay)
    loss_fn = nn.CrossEntropyLoss()

    for epoch in range(1, args.epochs + 1):
        model.train()
        train_loss, train_acc = run_epoch(model, train_loader, loss_fn, device, optimizer)

        if val_loader:
            model.eval()
            with torch.no_grad():
                val_loss, val_acc = run_epoch(model, val_loader, loss_fn, device)
            print(f"epoch={epoch} train_loss={train_loss:.5f} train_acc={train_acc:.3f} val_loss={val_loss:.5f} val_acc={val_acc:.3f}")
        else:
            print(f"epoch={epoch} train_loss={train_loss:.5f} train_acc={train_acc:.3f}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(
        {
            "model": model.state_dict(),
            "model_family": "mobilenet_v3_small",
            "task": "animacy-rarity-classification",
            "classes": dataset.classes,
            "input_size": [224, 224],
            "manifest": str(args.manifest),
        },
        args.output,
    )
    print(f"saved {args.output}")


def run_epoch(model, loader, loss_fn, device, optimizer=None):
    total_loss = 0.0
    total_count = 0
    correct_count = 0

    for images, targets in loader:
        images = images.to(device)
        targets = targets.to(device)
        logits = model(images)
        loss = loss_fn(logits, targets)

        if optimizer:
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            optimizer.step()

        total_loss += loss.item() * images.size(0)
        total_count += images.size(0)
        correct_count += (logits.argmax(dim=1) == targets).sum().item()

    return total_loss / max(total_count, 1), correct_count / max(total_count, 1)


def parse_args():
    parser = argparse.ArgumentParser(description="Fine-tune MobileNetV3-small for Exeligmos animacy rarity.")
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "sync-server" / "data" / "animacy" / "dataset-manifest.json",
    )
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent / "artifacts" / "animacy_mobilenetv3_small.pt")
    parser.add_argument("--epochs", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--lr", type=float, default=3e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--val-fraction", type=float, default=0.15)
    parser.add_argument("--workers", type=int, default=0)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--device", type=str, default="")
    return parser.parse_args()


if __name__ == "__main__":
    train(parse_args())
