import sys
import requests
import rasterio
import numpy as np
import os
import shutil
import csv
from rasterio.warp import calculate_default_transform, reproject, Resampling
from rasterio.crs import CRS

# === Leer parámetros de línea de comandos ===
west = float(sys.argv[1])
south = float(sys.argv[2])
east = float(sys.argv[3])
north = float(sys.argv[4])
depths_input = sys.argv[5] if len(sys.argv) > 5 else "100,500,1000,1500,2500"
depths = [int(d.strip()) for d in depths_input.split(",")]

print(f"📏 Profundidades a generar: {depths}")

# === Parámetros API ===
url = "https://portal.opentopography.org/API/globaldem"
params = {
    "demtype": "COP30",
    "south": south,
    "north": north,
    "west": west,
    "east": east,
    "outputFormat": "GTiff",
    "API_Key": "28dee87ae310cd639cf92b04ea1c6b55"
}

# === Descargar el DEM ===
response = requests.get(url, params=params)
if response.status_code == 200:
    output_filename = "copernicus_dem.tif"
    with open(output_filename, 'wb') as f:
        f.write(response.content)
    print(f"✅ DEM descargado como {output_filename}")
else:
    print(f"❌ Error al descargar DEM. Código: {response.status_code}")
    sys.exit(1)

# === Reproyectar a EPSG:3857 ===
target_epsg = 3857
reprojected_filename = "copernicus_dem_3857.tif"

with rasterio.open(output_filename) as src:
    dst_crs = CRS.from_epsg(target_epsg)
    transform, width, height = calculate_default_transform(
        src.crs, dst_crs, src.width, src.height, *src.bounds)

    dst_kwargs = src.meta.copy()
    dst_kwargs.update({
        'crs': dst_crs,
        'transform': transform,
        'width': width,
        'height': height,
        'driver': 'GTiff',
        'nodata': src.nodata
    })

    with rasterio.open(reprojected_filename, 'w', **dst_kwargs) as dst:
        for i in range(1, src.count + 1):
            reproject(
                source=rasterio.band(src, i),
                destination=rasterio.band(dst, i),
                src_transform=src.transform,
                src_crs=src.crs,
                dst_transform=transform,
                dst_crs=dst_crs,
                resampling=Resampling.nearest)

print(f"✅ DEM reproyectado a {reprojected_filename} (EPSG:{target_epsg})")

# === Convertir a XYZ ===
with rasterio.open(reprojected_filename) as src:
    band1 = src.read(1)
    transform = src.transform
    xyz_filename = reprojected_filename.replace('.tif', '.xyz')

    with open(xyz_filename, 'w', newline='') as csvfile:
        writer = csv.writer(csvfile, delimiter=' ')
        for row in range(band1.shape[0]):
            for col in range(band1.shape[1]):
                x, y = rasterio.transform.xy(transform, row, col)
                z = band1[row, col]
                if z != src.nodata:
                    writer.writerow([x, y, z])

print(f"✅ Exportado a {xyz_filename}")

# === Generar superficies desplazadas ===
for depth in depths:
    shifted_xyz_filename = reprojected_filename.replace('.tif', f'_minus{depth}m.xyz')
    with open(shifted_xyz_filename, 'w', newline='') as csvfile:
        writer = csv.writer(csvfile, delimiter=' ')
        for row in range(band1.shape[0]):
            for col in range(band1.shape[1]):
                x, y = rasterio.transform.xy(transform, row, col)
                z = band1[row, col]
                if z != src.nodata:
                    shifted_z = z - depth
                    writer.writerow([x, y, shifted_z])
    print(f"✅ Superficie -{depth} m exportada como {shifted_xyz_filename}")

# === Preparar carpetas de salida ===
os.makedirs('geometry', exist_ok=True)
os.makedirs('outputs', exist_ok=True)

# Mover todos los .xyz a geometry/
for file in os.listdir('.'):
    if file.endswith('.xyz'):
        shutil.move(file, os.path.join('geometry', file))
        print(f"📦 Movido {file} a carpeta geometry/")

# Guardar dimensiones en outputs/mesh_dimensions.txt
with rasterio.open(reprojected_filename) as src:
    width = src.width
    height = src.height
    with open(os.path.join('outputs', 'mesh_dimensions.txt'), 'w') as f:
        f.write(f"{width} {height}\n")
    print(f"✅ Dimensiones guardadas en outputs/mesh_dimensions.txt: {width} columnas, {height} filas")

# Copiar el archivo .tif final a outputs/
output_tif_path = os.path.join('outputs', 'copernicus_dem_3857.tif')
shutil.copy(reprojected_filename, output_tif_path)
print(f"✅ Archivo TIFF final copiado a {output_tif_path}")
