# Sistema de Gestión Hotelera - Grand Horizon Resort

Proyecto de Base de Datos Relacional desarrollado en **PostgreSQL**.

## 📌 Descripción
Este sistema soluciona los problemas de overbooking, descontrol de consumos y facturación desactualizada del complejo hotelero Grand Horizon Resort. El modelo está normalizado en 3FN y cuenta con exactamente 6 tablas.

## 🛠️ Tecnologías usadas
* **Motor:** PostgreSQL (Versión 18)
* **Cliente:** pgAdmin 4

## 📂 Contenido del repositorio
* `Proyecto_Hotel_Resort.sql`: Script completo que incluye la creación de tablas (DDL), inserción de datos (DML), vistas, triggers y el script de validación.
* `Diagrama.png`: Diagrama Entidad-Relación con notación Crow's Foot.

## 🚀 Características Principales
* **Restricción Anti-Overbooking:** Uso de `EXCLUDE USING gist` con `daterange` para evitar reservas duplicadas en las mismas fechas.
* **Lógica Activa (Triggers):** Automatización de cálculo de subtotales, totales de factura y cambio de estado de habitaciones (Check-in / Check-out).
* **Vistas de Negocio:** Consultas optimizadas para disponibilidad, resumen de estadía e ingresos mensuales.

## ⚙️ Cómo ejecutar
1. Crear una base de datos llamada `Hotel_Resort`.
2. Abrir el Query Tool en pgAdmin.
3. Ejecutar el archivo `Proyecto_Hotel_Resort.sql` en su totalidad.
4. Revisar la pestaña "Messages" para ver el resultado del script de validación (Checks ✔).
