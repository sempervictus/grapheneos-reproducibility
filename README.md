# Instructions

```bash
docker build -t gos-reproducibility .
```

```bash
docker run --privileged -v "./grapheneos-tree/:/opt/build/grapheneos/" gos-reproducibility
```
