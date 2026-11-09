-- ============================================================================
-- PROYECTO: SISTEMA DE GESTIÓN HOTELERA "GRAND HORIZON RESORT"
-- MOTOR: PostgreSQL
-- ============================================================================

-- ----------------------------------------------------------------------------
-- PASO 1: PREPARACIÓN DEL ENTORNO
-- ----------------------------------------------------------------------------
-- Extension necesaria para la restricción anti-overbooking (permite usar rangos de fechas)
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Los tipos ENUM evitan que se escriban datos basura (ej. 'Ocupado' en vez de 'Ocupada')
CREATE TYPE tipo_habitacion AS ENUM ('Sencilla', 'Doble', 'Suite');
CREATE TYPE estado_habitacion AS ENUM ('Disponible', 'Ocupada', 'Mantenimiento');
CREATE TYPE estado_reserva AS ENUM ('Confirmada', 'Activa', 'Finalizada', 'Cancelada');
CREATE TYPE categoria_servicio AS ENUM ('Restaurante', 'Spa', 'Lavanderia', 'Minibar', 'Otro');
CREATE TYPE estado_servicio AS ENUM ('Activo', 'Inactivo');
CREATE TYPE metodo_pago AS ENUM ('Efectivo', 'Tarjeta', 'Transferencia');
CREATE TYPE estado_pago AS ENUM ('Pendiente', 'Pagado');

-- ----------------------------------------------------------------------------
-- PASO 2: CREACIÓN DE TABLAS
-- ----------------------------------------------------------------------------
-- Limpiamos las tablas si ya existían (CASCADE borra las dependencias)
DROP TABLE IF EXISTS FACTURA CASCADE;
DROP TABLE IF EXISTS CONSUMO_SERVICIO CASCADE;
DROP TABLE IF EXISTS RESERVA CASCADE;
DROP TABLE IF EXISTS SERVICIO CASCADE;
DROP TABLE IF EXISTS HABITACION CASCADE;
DROP TABLE IF EXISTS HUESPED CASCADE;

-- TABLA 1: HABITACION (Catálogo de habitaciones)
CREATE TABLE HABITACION (
    -- GENERATED ALWAYS AS IDENTITY: El ID se genera solo (1, 2, 3...)
    id_habitacion INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, 
    numero_habitacion VARCHAR(10) NOT NULL UNIQUE, -- UNIQUE evita habitaciones duplicadas
    tipo tipo_habitacion NOT NULL,
    -- NUMERIC(10,2) es el tipo ideal para dinero (evita errores de redondeo)
    tarifa_noche NUMERIC(10,2) NOT NULL CHECK (tarifa_noche > 0), -- CHECK evita precios negativos
    piso INT NOT NULL CHECK (piso > 0),
    estado estado_habitacion NOT NULL DEFAULT 'Disponible' -- DEFAULT: si no se envía, es Disponible
);

-- TABLA 2: HUESPED (Catálogo de clientes)
CREATE TABLE HUESPED (
    id_huesped INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    documento_identidad VARCHAR(20) NOT NULL UNIQUE,
    nombres VARCHAR(100) NOT NULL,
    apellidos VARCHAR(100) NOT NULL,
    telefono VARCHAR(20),
    email VARCHAR(100) UNIQUE, -- UNIQUE evita que dos clientes tengan el mismo correo
    nacionalidad VARCHAR(50)
);

-- TABLA 3: SERVICIO (Catálogo de servicios adicionales)
CREATE TABLE SERVICIO (
    id_servicio INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo_servicio VARCHAR(20) NOT NULL UNIQUE,
    nombre VARCHAR(100) NOT NULL,
    categoria categoria_servicio NOT NULL,
    precio_unitario NUMERIC(10,2) NOT NULL CHECK (precio_unitario > 0),
    estado_servicio estado_servicio NOT NULL DEFAULT 'Activo'
);

-- TABLA 4: RESERVA (Tabla transaccional principal)
CREATE TABLE RESERVA (
    id_reserva INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo_reserva VARCHAR(20) NOT NULL UNIQUE,
    fecha_reserva DATE NOT NULL DEFAULT CURRENT_DATE,
    fecha_checkin DATE NOT NULL,
    fecha_checkout DATE NOT NULL,
    estado estado_reserva NOT NULL DEFAULT 'Confirmada',
    total_alojamiento NUMERIC(10,2),
    id_huesped INT NOT NULL,
    id_habitacion INT NOT NULL,
    
    -- Llaves Foráneas (conectan las tablas). No permite reservas de clientes/habitaciones inexistentes
    CONSTRAINT fk_reserva_huesped FOREIGN KEY (id_huesped) REFERENCES HUESPED(id_huesped),
    CONSTRAINT fk_reserva_habitacion FOREIGN KEY (id_habitacion) REFERENCES HABITACION(id_habitacion),
    
    -- Regla lógica: El Checkout debe ser mayor que el Checkin
    CONSTRAINT chk_fechas_validas CHECK (fecha_checkout > fecha_checkin),
    
    -- REGLA ANTI-OVERBOOKING: Bloquea solapamientos de fechas en la misma habitación.
    -- Usa un índice espacial (gist) y rangos de fechas (daterange) con el operador de intersección (&&).
    CONSTRAINT no_overbooking EXCLUDE USING gist (
        id_habitacion WITH =,
        daterange(fecha_checkin, fecha_checkout, '[]') WITH &&
    ) WHERE (estado IN ('Confirmada', 'Activa'))
);

-- TABLA 5: CONSUMO_SERVICIO (Detalle de lo que consume el huésped)
CREATE TABLE CONSUMO_SERVICIO (
    id_consumo INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fecha_consumo TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    cantidad INT NOT NULL CHECK (cantidad > 0),
    subtotal_consumo NUMERIC(10,2),
    notas_cargo TEXT,
    id_reserva INT NOT NULL,
    id_servicio INT NOT NULL,
    -- Si se borra la reserva, se borran sus consumos (ON DELETE CASCADE)
    CONSTRAINT fk_consumo_reserva FOREIGN KEY (id_reserva) REFERENCES RESERVA(id_reserva) ON DELETE CASCADE,
    CONSTRAINT fk_consumo_servicio FOREIGN KEY (id_servicio) REFERENCES SERVICIO(id_servicio)
);

-- TABLA 6: FACTURA (Cobro final)
CREATE TABLE FACTURA (
    id_factura INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    numero_factura VARCHAR(20) NOT NULL UNIQUE,
    fecha_emision TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    total_hospedaje NUMERIC(10,2) DEFAULT 0,
    total_servicios NUMERIC(10,2) DEFAULT 0,
    total_general NUMERIC(10,2) DEFAULT 0,
    metodo_pago metodo_pago,
    estado_pago estado_pago NOT NULL DEFAULT 'Pendiente',
    -- UNIQUE garantiza relación 1 a 1 (una reserva solo tiene una factura)
    id_reserva INT NOT NULL UNIQUE,
    CONSTRAINT fk_factura_reserva FOREIGN KEY (id_reserva) REFERENCES RESERVA(id_reserva)
);

-- Índices: aceleran las búsquedas (como el índice de un libro)
CREATE INDEX idx_reserva_estado ON RESERVA(estado);
CREATE INDEX idx_consumo_reserva ON CONSUMO_SERVICIO(id_reserva);
CREATE INDEX idx_factura_fecha ON FACTURA(fecha_emision);

-- ----------------------------------------------------------------------------
-- PASO 3: LÓGICA ACTIVA (TRIGGERS)
-- ----------------------------------------------------------------------------

-- TRIGGER 1: Sincroniza el estado de la habitación al hacer Check-in / Check-out
CREATE OR REPLACE FUNCTION fn_actualizar_estado_habitacion() RETURNS TRIGGER AS $$
DECLARE v_estado_habitacion estado_habitacion;
BEGIN
    -- Si la reserva se activa (Check-in)
    IF (TG_OP = 'INSERT' AND NEW.estado = 'Activa') OR (TG_OP = 'UPDATE' AND NEW.estado = 'Activa' AND OLD.estado IS DISTINCT FROM 'Activa') THEN
        SELECT estado INTO v_estado_habitacion FROM HABITACION WHERE id_habitacion = NEW.id_habitacion;
        -- Si ya está ocupada, aborta la operación con un error
        IF v_estado_habitacion = 'Ocupada' THEN
            RAISE EXCEPTION 'No se puede hacer Check-in: la habitación % ya está ocupada.', NEW.id_habitacion;
        END IF;
        UPDATE HABITACION SET estado = 'Ocupada' WHERE id_habitacion = NEW.id_habitacion;
    
    -- Si la reserva se finaliza o cancela (Check-out)
    ELSIF (TG_OP = 'UPDATE' AND NEW.estado IN ('Finalizada', 'Cancelada') AND OLD.estado NOT IN ('Finalizada', 'Cancelada')) THEN
        UPDATE HABITACION SET estado = 'Disponible' WHERE id_habitacion = NEW.id_habitacion;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Se ejecuta DESPUÉS de insertar/actualizar, porque modifica la tabla HABITACION
CREATE TRIGGER TR_ActualizarEstadoHabitacion AFTER INSERT OR UPDATE ON RESERVA FOR EACH ROW EXECUTE FUNCTION fn_actualizar_estado_habitacion();

-- TRIGGER 2: Calcula subtotales de consumo y valida que el servicio esté activo
CREATE OR REPLACE FUNCTION fn_calcular_subtotal_consumo() RETURNS TRIGGER AS $$
DECLARE 
    v_precio_unitario NUMERIC(10,2); 
    v_estado_servicio estado_servicio;
BEGIN
    SELECT precio_unitario, estado_servicio INTO v_precio_unitario, v_estado_servicio FROM SERVICIO WHERE id_servicio = NEW.id_servicio;
    IF v_estado_servicio <> 'Activo' THEN
        RAISE EXCEPTION 'El servicio ID % no está activo. No se puede registrar el consumo.', NEW.id_servicio;
    END IF;
    -- Calcula el subtotal automáticamente (cantidad x precio)
    NEW.subtotal_consumo := NEW.cantidad * v_precio_unitario;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Se ejecuta ANTES de insertar/actualizar para modificar el valor antes de guardarlo
CREATE TRIGGER TR_CalcularSubtotalConsumo BEFORE INSERT OR UPDATE ON CONSUMO_SERVICIO FOR EACH ROW EXECUTE FUNCTION fn_calcular_subtotal_consumo();

-- TRIGGER 3: Calcula automáticamente los totales de la factura
CREATE OR REPLACE FUNCTION fn_generar_totales_factura() RETURNS TRIGGER AS $$
DECLARE
    v_fecha_checkin DATE; v_fecha_checkout DATE; v_id_habitacion INT;
    v_tarifa_noche NUMERIC(10,2); v_noches INT;
BEGIN
    -- Obtiene fechas y habitación de la reserva
    SELECT fecha_checkin, fecha_checkout, id_habitacion INTO v_fecha_checkin, v_fecha_checkout, v_id_habitacion FROM RESERVA WHERE id_reserva = NEW.id_reserva;
    SELECT tarifa_noche INTO v_tarifa_noche FROM HABITACION WHERE id_habitacion = v_id_habitacion;
    
    -- Calcula los días de estadía
    v_noches := v_fecha_checkout - v_fecha_checkin;
    IF v_noches <= 0 THEN v_noches := 1; END IF; -- Mínimo 1 noche por seguridad
    
    -- Calcula total hospedaje y suma los consumos (COALESCE convierte NULL en 0)
    NEW.total_hospedaje := v_noches * v_tarifa_noche;
    SELECT COALESCE(SUM(subtotal_consumo), 0) INTO NEW.total_servicios FROM CONSUMO_SERVICIO WHERE id_reserva = NEW.id_reserva;
    NEW.total_general := NEW.total_hospedaje + NEW.total_servicios;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER TR_GenerarTotalesFactura BEFORE INSERT ON FACTURA FOR EACH ROW EXECUTE FUNCTION fn_generar_totales_factura();

-- ----------------------------------------------------------------------------
-- PASO 4: DATOS DE PRUEBA (10 registros por tabla)
-- ----------------------------------------------------------------------------
INSERT INTO HABITACION (numero_habitacion, tipo, tarifa_noche, piso, estado) VALUES
('101', 'Sencilla', 120.00, 1, 'Disponible'), ('102', 'Sencilla', 120.00, 1, 'Disponible'),
('201', 'Doble', 180.00, 2, 'Disponible'), ('202', 'Doble', 180.00, 2, 'Disponible'),
('301', 'Suite', 350.00, 3, 'Disponible'), ('302', 'Suite', 350.00, 3, 'Disponible'),
('401', 'Doble', 200.00, 4, 'Disponible'), ('402', 'Sencilla', 130.00, 4, 'Mantenimiento'),
('501', 'Suite', 400.00, 5, 'Disponible'), ('502', 'Doble', 190.00, 5, 'Disponible');

INSERT INTO HUESPED (documento_identidad, nombres, apellidos, telefono, email, nacionalidad) VALUES
('12345678', 'Juan', 'Pérez', '3001112233', 'juan@mail.com', 'Colombiana'),
('87654321', 'María', 'Gómez', '3002223344', 'maria@mail.com', 'Colombiana'),
('11223344', 'Carlos', 'Rodríguez', '3003334455', 'carlos@mail.com', 'Mexicana'),
('44332211', 'Ana', 'Martínez', '3004445566', 'ana@mail.com', 'Argentina'),
('55667788', 'Luis', 'Fernández', '3005556677', 'luis@mail.com', 'Chilena'),
('99887766', 'Laura', 'Sánchez', '3006667788', 'laura@mail.com', 'Colombiana'),
('22334455', 'Pedro', 'Ramírez', '3007778899', 'pedro@mail.com', 'Peruana'),
('66778899', 'Sofía', 'Torres', '3008889900', 'sofia@mail.com', 'Ecuatoriana'),
('33445566', 'Diego', 'Vargas', '3009990011', 'diego@mail.com', 'Colombiana'),
('77889900', 'Elena', 'Castro', '3000001122', 'elena@mail.com', 'Española');

INSERT INTO SERVICIO (codigo_servicio, nombre, categoria, precio_unitario, estado_servicio) VALUES
('SRV001', 'Desayuno Buffet', 'Restaurante', 25.00, 'Activo'), ('SRV002', 'Almuerzo Ejecutivo', 'Restaurante', 35.00, 'Activo'),
('SRV003', 'Cena Gourmet', 'Restaurante', 60.00, 'Activo'), ('SRV004', 'Masaje Relajante', 'Spa', 80.00, 'Activo'),
('SRV005', 'Circuito Spa', 'Spa', 120.00, 'Activo'), ('SRV006', 'Lavado de Ropa', 'Lavanderia', 15.00, 'Activo'),
('SRV007', 'Planchado', 'Lavanderia', 10.00, 'Activo'), ('SRV008', 'Minibar - Agua', 'Minibar', 3.00, 'Activo'),
('SRV009', 'Minibar - Snacks', 'Minibar', 8.00, 'Activo'), ('SRV010', 'Tour Guiado', 'Otro', 50.00, 'Inactivo');

INSERT INTO RESERVA (codigo_reserva, fecha_reserva, fecha_checkin, fecha_checkout, estado, id_huesped, id_habitacion) VALUES
('RES-001', '2024-01-05', '2024-01-10', '2024-01-15', 'Finalizada', 1, 1),
('RES-002', '2024-01-08', '2024-01-12', '2024-01-14', 'Finalizada', 2, 3),
('RES-003', '2024-02-01', '2024-02-05', '2024-02-08', 'Cancelada', 3, 5),
('RES-004', '2024-02-10', '2024-02-15', '2024-02-18', 'Finalizada', 4, 4),
('RES-005', '2024-03-01', '2024-03-05', '2024-03-07', 'Activa', 5, 7),    -- Dispara Trigger 1 (Hab 7 a Ocupada)
('RES-006', '2024-03-02', '2024-03-06', '2024-03-09', 'Activa', 6, 2),    -- Dispara Trigger 1 (Hab 2 a Ocupada)
('RES-007', '2024-03-03', '2024-03-07', '2024-03-10', 'Confirmada', 7, 6),
('RES-008', '2024-03-04', '2024-03-08', '2024-03-11', 'Confirmada', 8, 10),
('RES-009', '2024-03-05', '2024-03-09', '2024-03-12', 'Confirmada', 9, 9),
('RES-010', '2024-03-06', '2024-03-10', '2024-03-13', 'Confirmada', 10, 8);

INSERT INTO CONSUMO_SERVICIO (fecha_consumo, cantidad, notas_cargo, id_reserva, id_servicio) VALUES
('2024-01-10 08:30:00', 2, 'Desayuno pareja', 1, 1), ('2024-01-11 13:00:00', 2, 'Almuerzo', 1, 2),
('2024-01-12 20:00:00', 1, 'Cena', 1, 3), ('2024-01-12 10:00:00', 1, 'Masaje', 2, 4),
('2024-01-13 09:00:00', 1, 'Lavado', 2, 6), ('2024-02-05 15:00:00', 2, 'Circuito spa', 3, 5),
('2024-02-06 11:00:00', 3, 'Aguas', 3, 8), ('2024-02-07 21:00:00', 1, 'Cena', 3, 3),
('2024-03-05 08:00:00', 1, 'Desayuno', 5, 1), ('2024-03-06 14:00:00', 1, 'Almuerzo', 6, 2);

INSERT INTO FACTURA (numero_factura, metodo_pago, estado_pago, id_reserva) VALUES
('FAC-001', 'Tarjeta', 'Pagado', 1), ('FAC-002', 'Efectivo', 'Pagado', 2),
('FAC-003', 'Transferencia', 'Pagado', 3), ('FAC-004', 'Tarjeta', 'Pendiente', 4),
('FAC-005', 'Efectivo', 'Pendiente', 5), ('FAC-006', 'Tarjeta', 'Pendiente', 6),
('FAC-007', 'Transferencia', 'Pendiente', 7), ('FAC-008', 'Efectivo', 'Pendiente', 8),
('FAC-009', 'Tarjeta', 'Pendiente', 9), ('FAC-010', 'Transferencia', 'Pendiente', 10);

-- ----------------------------------------------------------------------------
-- PASO 5: VISTAS
-- ----------------------------------------------------------------------------
-- Vista 1: Muestra solo las habitaciones disponibles ordenadas por precio
CREATE OR REPLACE VIEW V_HabitacionesDisponibles AS
SELECT numero_habitacion, tipo, piso, tarifa_noche
FROM HABITACION WHERE estado = 'Disponible' ORDER BY tarifa_noche ASC;

-- Vista 2: Estado financiero de reservas activas
CREATE OR REPLACE VIEW V_ResumenEstadiaConsumos AS
SELECT 
    r.codigo_reserva, 
    h.nombres || ' ' || h.apellidos AS nombre_huesped, -- Concatenación de nombre
    hab.numero_habitacion,
    (CURRENT_DATE - r.fecha_checkin) AS dias_transcurridos, -- Cálculo de días
    (CURRENT_DATE - r.fecha_checkin) * hab.tarifa_noche AS subtotal_alojamiento,
    COALESCE(SUM(cs.subtotal_consumo), 0) AS total_consumos -- Suma consumos (0 si no hay)
FROM RESERVA r
INNER JOIN HUESPED h ON r.id_huesped = h.id_huesped
INNER JOIN HABITACION hab ON r.id_habitacion = hab.id_habitacion
LEFT JOIN CONSUMO_SERVICIO cs ON r.id_reserva = cs.id_reserva -- LEFT JOIN para incluir reservas sin consumos
WHERE r.estado = 'Activa'
GROUP BY r.codigo_reserva, h.nombres, h.apellidos, hab.numero_habitacion, r.fecha_checkin, hab.tarifa_noche;

-- Vista 3: Ingresos agrupados por mes y tipo
CREATE OR REPLACE VIEW V_IngresosMensualesPorTipo AS
SELECT TO_CHAR(mes, 'YYYY-MM') AS anio_mes, categoria, total_ingresos
FROM (
    -- Parte 1: Ingresos por habitaciones según su tipo
    SELECT DATE_TRUNC('month', f.fecha_emision) AS mes, 'Habitación - ' || CAST(hab.tipo AS VARCHAR) AS categoria, SUM(f.total_hospedaje) AS total_ingresos
    FROM FACTURA f INNER JOIN RESERVA r ON f.id_reserva = r.id_reserva INNER JOIN HABITACION hab ON r.id_habitacion = hab.id_habitacion
    GROUP BY DATE_TRUNC('month', f.fecha_emision), hab.tipo
    UNION ALL
    -- Parte 2: Ingresos por servicios adicionales
    SELECT DATE_TRUNC('month', f.fecha_emision) AS mes, 'Servicios Adicionales' AS categoria, SUM(f.total_servicios) AS total_ingresos
    FROM FACTURA f GROUP BY DATE_TRUNC('month', f.fecha_emision)
) AS sub ORDER BY mes ASC, categoria ASC;

-- ----------------------------------------------------------------------------
-- PASO 6: SCRIPT DE VALIDACIÓN (Bloques DO para probar los triggers)
-- ----------------------------------------------------------------------------
-- Usamos EXCEPTION WHEN OTHERS para capturar el error esperado y mostrarlo en pantalla
DO $$
DECLARE v_subtotal NUMERIC;
BEGIN
    INSERT INTO CONSUMO_SERVICIO (cantidad, id_reserva, id_servicio) VALUES (3, 5, 8);
    SELECT subtotal_consumo INTO v_subtotal FROM CONSUMO_SERVICIO WHERE id_reserva = 5 AND id_servicio = 8 ORDER BY id_consumo DESC LIMIT 1;
    IF v_subtotal = 9.00 THEN RAISE NOTICE '✔ PRUEBA 1: Subtotales correctos (Esperado 9.00, Obtenido %)', v_subtotal; END IF;
END $$;

DO $$
BEGIN
    INSERT INTO CONSUMO_SERVICIO (cantidad, id_reserva, id_servicio) VALUES (1, 5, 10);
    RAISE EXCEPTION 'FALLIDA: Se permitió consumir un servicio inactivo.';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE '✔ PRUEBA 2: Rechazado correctamente -> %', SQLERRM; END $$;

DO $$
DECLARE v_estado estado_habitacion;
BEGIN
    UPDATE RESERVA SET estado = 'Activa' WHERE codigo_reserva = 'RES-007';
    SELECT estado INTO v_estado FROM HABITACION WHERE id_habitacion = 6;
    IF v_estado = 'Ocupada' THEN RAISE NOTICE '✔ PRUEBA 3: Habitación 6 marcada como Ocupada tras Check-in.'; END IF;
END $$;

DO $$
BEGIN
    INSERT INTO RESERVA (codigo_reserva, fecha_checkin, fecha_checkout, estado, id_huesped, id_habitacion) VALUES ('RES-TEST', '2024-05-01', '2024-05-05', 'Activa', 1, 6);
    RAISE EXCEPTION 'FALLIDA: Se permitió Check-in en habitación ocupada.';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE '✔ PRUEBA 4: Rechazado correctamente -> %', SQLERRM; END $$;

DO $$
BEGIN
    INSERT INTO RESERVA (codigo_reserva, fecha_checkin, fecha_checkout, estado, id_huesped, id_habitacion) VALUES ('RES-OVERLAP', '2024-01-12', '2024-01-16', 'Confirmada', 2, 1);
    RAISE EXCEPTION 'FALLIDA: Se permitió un Overbooking.';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE '✔ PRUEBA 5: Overbooking bloqueado -> %', SQLERRM; END $$;

DO $$
BEGIN
    INSERT INTO RESERVA (codigo_reserva, fecha_checkin, fecha_checkout, estado, id_huesped, id_habitacion) VALUES ('RES-BAD-DATE', '2024-06-10', '2024-06-08', 'Confirmada', 1, 1);
    RAISE EXCEPTION 'FALLIDA: Se permitieron fechas ilógicas.';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE '✔ PRUEBA 6: Fechas inválidas rechazadas -> %', SQLERRM; END $$;