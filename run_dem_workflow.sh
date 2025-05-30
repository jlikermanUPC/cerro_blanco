#!/bin/bash

# === Mostrar ayuda si se pide ===
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo ""
    echo "Uso:"
    echo "  ./run_dem_workflow.sh WEST SOUTH EAST NORTH [DEPTHS] [REFINEMENTS] [--dry-run]"
    echo ""
    echo "Descripción:"
    echo "  Corre el workflow completo para descargar el DEM, reproyectarlo,"
    echo "  generar superficies desplazadas, exportar archivos XYZ,"
    echo "  generar archivos geometry_Shallow.i y refinement.i,"
    echo "  y actualizar el archivo CerroBlanco.ini con las dimensiones correctas."
    echo ""
    echo "Argumentos:"
    echo "  WEST         Longitud oeste (ej: -67.8)"
    echo "  SOUTH        Latitud sur (ej: -26.8)"
    echo "  EAST         Longitud este (ej: -67.69)"
    echo "  NORTH        Latitud norte (ej: -26.73)"
    echo "  DEPTHS       (opcional) Lista separada por comas de profundidades en metros."
    echo "               Si no se pasa, usa por defecto: 100,500,1000,1500,2500"
    echo "  REFINEMENTS  (opcional) Lista separada por comas de refinamientos por capa."
    echo "               Debe tener uno menos que el número de superficies."
    echo "  --dry-run    (opcional) Si se incluye, no se ejecutan pasos pesados ni descargas, solo se preparan archivos."
    echo ""
    echo "Ejemplo:"
    echo "  ./run_dem_workflow.sh -67.8 -26.8 -67.69 -26.73 100,300,600 2,2,2 --dry-run"
    echo ""
    exit 0
fi

# === Leer argumentos ===
WEST="$1"
SOUTH="$2"
EAST="$3"
NORTH="$4"
DEPTHS="$5"
REFINEMENTS="$6"
DRY_FLAG="$7"

if [ -z "$DEPTHS" ]; then
    DEPTHS="100,500,1000,1500,2500"
fi

if [ -z "$REFINEMENTS" ]; then
    REFINEMENTS="2,2,2,2"
fi

if [[ "$DRY_FLAG" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "🧪 MODO DRY RUN ACTIVADO: solo se generarán archivos, no se correrán simulaciones ni descargas pesadas."
else
    DRY_RUN=false
fi

# === Limpiar archivos previos ===
echo "🧹 Limpiando archivos previos..."
rm -f geometry_Shallow.i refinement.i CerroBlanco_temp.ini
rm -f geometry/*.xyz 2>/dev/null

# Calcular cantidades
IFS=',' read -r -a depths_array <<< "$DEPTHS"
IFS=',' read -r -a refinements_array <<< "$REFINEMENTS"

num_surfaces=$(( ${#depths_array[@]} + 1 ))
num_refinements=${#refinements_array[@]}

if [ "$num_refinements" -ne $((num_surfaces - 1)) ]; then
    echo "❌ Error: cantidad de refinamientos ($num_refinements) no coincide con número de capas entre superficies ($((num_surfaces - 1)))."
    echo "Tenés ${#depths_array[@]} profundidades → $num_surfaces superficies → se esperan $((num_surfaces - 1)) refinamientos."
    exit 1
fi

echo "✅ Chequeo pasado: $num_surfaces superficies, $num_refinements refinamientos."

# === Archivo de log ===
LOGFILE="workflow_log_$(date +%Y%m%d_%H%M%S).log"
echo "📝 Log guardado en $LOGFILE"
exec > >(tee -i "$LOGFILE") 2>&1

check_error() {
    if [ $? -ne 0 ]; then
        echo "❌ Error en el paso: $1"
        echo "Revisá el log $LOGFILE para más detalles."
        exit 1
    fi
}

if [ "$DRY_RUN" = true ]; then
    echo "🔹 Saltando entorno virtual, instalación de paquetes y descarga de DEM (dry run)"
else
    # === Crear entorno virtual ===
    echo "🚀 Creando entorno virtual..."
    python3 -m venv dem_env
    check_error "crear entorno virtual"

    source dem_env/bin/activate
    check_error "activar entorno virtual"

    # === Instalar paquetes ===
    echo "📦 Instalando paquetes Python..."
    pip install --upgrade pip
    check_error "actualizar pip"

    pip install requests rasterio matplotlib pyproj
    check_error "instalar paquetes Python"

    # === Ejecutar script Python ===
    echo "🏗️ Ejecutando script dem2xyz.py..."
    python3 dem2xyz.py "$WEST" "$SOUTH" "$EAST" "$NORTH" "$DEPTHS"
    check_error "ejecutar script Python"

    # === Desactivar entorno virtual ===
    echo "🛑 Desactivando entorno virtual..."
    deactivate
fi

# === Chequeo de archivos generados ===
if [ ! -d "geometry" ] || [ -z "$(ls geometry/*.xyz 2>/dev/null)" ]; then
    echo "❌ Error: no se encontraron archivos .xyz en geometry/"
    exit 1
fi

# === Generar archivo geometry_Shallow.i ===
GEOMETRY_FILE="geometry_Shallow.i"
echo "🚀 Generando $GEOMETRY_FILE..."
> "$GEOMETRY_FILE"
for file in geometry/*.xyz; do
    echo "$file GRID_DATA" >> "$GEOMETRY_FILE"
done
echo "✅ Archivo $GEOMETRY_FILE generado:"
cat "$GEOMETRY_FILE"

# === Generar archivo refinement.i ===
REFINEMENT_FILE="refinement.i"
echo "🚀 Generando $REFINEMENT_FILE..."
> "$REFINEMENT_FILE"
echo "# list of refinement for each single layer inthe model" >> "$REFINEMENT_FILE"
echo "# number of layers must be equal to number of surfaces (set by #GEOMETRY)" >> "$REFINEMENT_FILE"
for i in "${!refinements_array[@]}"; do
    echo "${refinements_array[$i]}" >> "$REFINEMENT_FILE"
done
echo "✅ Archivo $REFINEMENT_FILE generado:"
cat "$REFINEMENT_FILE"

# === Leer dimensiones correctas ===
if [ ! -f outputs/mesh_dimensions.txt ]; then
    echo "❌ Error: no se encontró outputs/mesh_dimensions.txt generado por el script Python."
    exit 1
fi

read WIDTH HEIGHT < outputs/mesh_dimensions.txt
NUM_COLUMNS=$WIDTH
NUM_ROWS=$HEIGHT

echo "✅ Dimensiones detectadas: $NUM_COLUMNS columnas, $NUM_ROWS filas (verificá si necesitan invertirse para #GRID_DIMENSION)"

# === Actualizar CerroBlanco.ini con respaldo ===
INI_FILE="CerroBlanco.ini"
BACKUP_FILE="${INI_FILE}.bak"
TEMP_FILE="CerroBlanco_temp.ini"
echo "🚀 Haciendo backup de $INI_FILE → $BACKUP_FILE..."
cp "$INI_FILE" "$BACKUP_FILE"
cp "$INI_FILE" "$TEMP_FILE"

# Aquí podés invertir NUM_COLUMNS y NUM_ROWS si notas que se guardan mal:
# sed -i "s|#GRID_DIMENSION .*|#GRID_DIMENSION $NUM_ROWS $NUM_COLUMNS|" "$TEMP_FILE"
sed -i "s|#GRID_DIMENSION .*|#GRID_DIMENSION $NUM_COLUMNS $NUM_ROWS|" "$TEMP_FILE"
sed -i "s|#GEOMETRY .*|#GEOMETRY geometry_Shallow.i|" "$TEMP_FILE"
sed -i "s|#REFINEMENT .*|#REFINEMENT refinement.i|" "$TEMP_FILE"

mv "$TEMP_FILE" "$INI_FILE"

echo "✅ $INI_FILE actualizado (backup guardado en $BACKUP_FILE):"
cat "$INI_FILE"

echo "✅ Workflow completo (dry run: $DRY_RUN)"
