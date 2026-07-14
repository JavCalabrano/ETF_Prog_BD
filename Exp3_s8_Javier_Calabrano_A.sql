
-- Limpieza de objetos existentes (para recreación)
DROP TRIGGER TRG_PRODUCTO_BLOCK;
DROP TRIGGER TRG_PRODUCTO_RECALC;
DROP PROCEDURE P_MAIN_LIQUIDACION;
DROP FUNCTION F_QUALIFIES_FOR_SENIORITY;
DROP FUNCTION F_STUDY_PCT;
DROP FUNCTION F_SENIORITY_PCT;
DROP PACKAGE PKG_LIQUIDACION;


-- PACKAGE PKG_LIQUIDACION
CREATE OR REPLACE PACKAGE PKG_LIQUIDACION AS
    -- Variable pública promedio de ventas del año anterior
    g_avg_sales_prev_year NUMBER;

    -- Variable pública fecha de proceso (mes/año)
    g_process_date DATE;

    -- Procedimiento para insertar errores en ERROR_CALC
    PROCEDURE p_insert_error(p_rutina_error VARCHAR2,
                             p_descrip_error VARCHAR2,
                             p_descrip_user VARCHAR2);

    -- Función el promedio de ventas del año anterior
    FUNCTION f_avg_sales_prev_year RETURN NUMBER;
END PKG_LIQUIDACION;
/

CREATE OR REPLACE PACKAGE BODY PKG_LIQUIDACION AS

    PROCEDURE p_insert_error(p_rutina_error VARCHAR2,
                             p_descrip_error VARCHAR2,
                             p_descrip_user VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO ERROR_CALC (CORREL_ERROR, RUTINA_ERROR, DESCRIP_ERROR, DESCRIP_USER)
        VALUES (SEQ_ERROR.NEXTVAL, p_rutina_error, p_descrip_error, p_descrip_user);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END p_insert_error;

    FUNCTION f_avg_sales_prev_year RETURN NUMBER IS
        v_avg NUMBER;
    BEGIN
        SELECT AVG(MONTO_TOTAL_BOLETA)
        INTO v_avg
        FROM BOLETA
        WHERE EXTRACT(YEAR FROM FECHA) = EXTRACT(YEAR FROM SYSDATE) - 1
          AND MONTO_TOTAL_BOLETA IS NOT NULL;

        RETURN NVL(v_avg, 0);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN 0;
        WHEN OTHERS THEN
            RETURN 0;
    END f_avg_sales_prev_year;

END PKG_LIQUIDACION;
/

-- FUNCIONES
-- Función que retorna el porcentaje por antigüedad
CREATE OR REPLACE FUNCTION f_seniority_pct(p_run_empleado VARCHAR2) RETURN NUMBER IS
    v_years NUMBER;
    v_pct   NUMBER;
BEGIN
    -- Calcular años de servicio 
    SELECT MONTHS_BETWEEN(PKG_LIQUIDACION.g_process_date, FECHA_CONTRATO) / 12
    INTO v_years
    FROM EMPLEADO
    WHERE RUN_EMPLEADO = p_run_empleado;

    -- Obtener el porcentaje según los años
    SELECT PORC_ANTIGUEDAD
    INTO v_pct
    FROM PCT_ANTIGUEDAD
    WHERE v_years BETWEEN ANNOS_ANTIGUEDAD_INF AND ANNOS_ANTIGUEDAD_SUP;

    RETURN v_pct;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        -- No se encontró tramo
        PKG_LIQUIDACION.p_insert_error(
            'FN_CTP_ESPECIAL',
            'ORA-01483: No se ha encontrado ningún dato',
            'Error al calcular PCT ESPECIAL'
        );
        RETURN 0;
    WHEN OTHERS THEN
        -- Cualquier otro error
        PKG_LIQUIDACION.p_insert_error(
            'FN_CTP_ESPECIAL',
            SQLERRM,
            'Error al calcular PCT ESPECIAL'
        );
        RETURN 0;
END f_seniority_pct;
/

-- Función que retorna el porcentaje por nivel de estudios
CREATE OR REPLACE FUNCTION f_study_pct(p_run_empleado VARCHAR2) RETURN NUMBER IS
    v_cod_escolaridad EMPLEADO.COD_ESCOLARIDAD%TYPE;
    v_pct             NUMBER;
BEGIN
    -- Obtener código de escolaridad
    SELECT COD_ESCOLARIDAD
    INTO v_cod_escolaridad
    FROM EMPLEADO
    WHERE RUN_EMPLEADO = p_run_empleado;

    -- Obtener el porcentaje
    SELECT PORC_ESCOLARIDAD
    INTO v_pct
    FROM PCT_NIVEL_ESTUDIOS
    WHERE COD_ESCOLARIDAD = v_cod_escolaridad;

    RETURN v_pct;
EXCEPTION
    WHEN TOO_MANY_ROWS THEN
        -- Se registra el error 
        PKG_LIQUIDACION.p_insert_error(
            'FN_ESTUDIOS',
            'ORA-01422: la recuperación exacta devuelve un número mayor de filas que el solicitado',
            'Error al calcular nivel de estudios'
        );
        RETURN 0;
    WHEN NO_DATA_FOUND THEN
        PKG_LIQUIDACION.p_insert_error(
            'FN_ESTUDIOS',
            'ORA-01403: no se han encontrado datos',
            'Error al calcular nivel de estudios'
        );
        RETURN 0;
    WHEN OTHERS THEN
        PKG_LIQUIDACION.p_insert_error(
            'FN_ESTUDIOS',
            SQLERRM,
            'Error al calcular nivel de estudios'
        );
        RETURN 0;
END f_study_pct;
/

-- Función que determina si el vendedor cumple con la condición
CREATE OR REPLACE FUNCTION f_qualifies_for_seniority(p_run_empleado VARCHAR2,
                                                     p_year NUMBER) RETURN NUMBER IS
    v_total_ventas   NUMBER;
    v_siete_porciento NUMBER;
BEGIN
    -- Calcular el total de ventas del vendedor
    SELECT NVL(SUM(MONTO_TOTAL_BOLETA), 0)
    INTO v_total_ventas
    FROM BOLETA
    WHERE RUN_EMPLEADO = p_run_empleado
      AND EXTRACT(YEAR FROM FECHA) = p_year;

    v_siete_porciento := v_total_ventas * 0.07;

    -- Comparar con el promedio de ventas del año anterior
    IF v_siete_porciento > PKG_LIQUIDACION.g_avg_sales_prev_year THEN
        RETURN 1;
    ELSE
        RETURN 0;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        -- En caso de error, se retorna 0
        RETURN 0;
END f_qualifies_for_seniority;
/


-- PROCEDIMIENTO ALMACENADO PRINCIPAL
CREATE OR REPLACE PROCEDURE p_main_liquidacion(p_mes NUMBER, p_anno NUMBER) IS
    -- Cursor para recorrer todos los empleados
    CURSOR c_empleados IS
        SELECT RUN_EMPLEADO,
               NOMBRE,
               PATERNO,
               MATERNO,
               SUELDO_BASE,
               TIPO_EMPLEADO,
               COD_SALUD,
               FECHA_CONTRATO,
               COD_ESCOLARIDAD
        FROM EMPLEADO;

    v_asig_especial  NUMBER;
    v_asig_estudios  NUMBER;
    v_total_haberes  NUMBER;
    v_pct            NUMBER;
    v_qualifies      NUMBER;
BEGIN
    --Truncar tablas de resultados
    EXECUTE IMMEDIATE 'TRUNCATE TABLE LIQUIDACION_EMPLEADO';
    EXECUTE IMMEDIATE 'TRUNCATE TABLE ERROR_CALC';

    --Establecer fecha de proceso en el package
    PKG_LIQUIDACION.g_process_date := TO_DATE(p_anno || '-' || p_mes || '-01', 'YYYY-MM-DD');

    --Calcular promedio de ventas del año anterior y almacenarlo
    PKG_LIQUIDACION.g_avg_sales_prev_year := PKG_LIQUIDACION.f_avg_sales_prev_year;

    --Procesar cada empleado
    FOR rec IN c_empleados LOOP
        -- Inicializar asignaciones en 0
        v_asig_especial := 0;
        v_asig_estudios := 0;

        -- ASIGNACIÓN ESPECIAL POR ANTIGÜEDAD (solo vendedores)
        IF rec.TIPO_EMPLEADO = 5 THEN -- 5 = VENDEDOR
            v_qualifies := f_qualifies_for_seniority(rec.RUN_EMPLEADO, p_anno);
            IF v_qualifies = 1 THEN
                v_pct := f_seniority_pct(rec.RUN_EMPLEADO);
                v_asig_especial := rec.SUELDO_BASE * v_pct / 100;
            END IF;
        END IF;

        -- ASIGNACIÓN POR NIVEL DE ESTUDIOS (solo empleados con FONASA)
        IF rec.COD_SALUD = 1 THEN -- 1 = FONASA
            v_pct := f_study_pct(rec.RUN_EMPLEADO);
            v_asig_estudios := rec.SUELDO_BASE * v_pct / 100;
        END IF;

        -- Total de haberes
        v_total_haberes := rec.SUELDO_BASE + v_asig_especial + v_asig_estudios;

        -- Insertar en la tabla de liquidación
        INSERT INTO LIQUIDACION_EMPLEADO (
            MES, ANNO, RUN_EMPLEADO, NOMBRE_EMPLEADO,
            SUELDO_BASE, ASIG_ESPECIAL, ASIG_ESTUDIOS, TOTAL_HABERES
        ) VALUES (
            p_mes, p_anno, rec.RUN_EMPLEADO,
            rec.NOMBRE || ' ' || rec.PATERNO || ' ' || rec.MATERNO,
            rec.SUELDO_BASE, v_asig_especial, v_asig_estudios, v_total_haberes
        );
    END LOOP;

    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END p_main_liquidacion;
/


-- TRIGGERS
-- Trigger BEFORE INSERT OR DELETE para bloquear operaciones en días hábiles
CREATE OR REPLACE TRIGGER TRG_PRODUCTO_BLOCK
    BEFORE INSERT OR DELETE ON PRODUCTO
DECLARE
    v_day_number NUMBER;
BEGIN
    -- Obtener número de día (lunes=2, martes=3, ..., viernes=6)
    SELECT TO_CHAR(SYSDATE, 'D', 'NLS_DATE_LANGUAGE=AMERICAN')
    INTO v_day_number
    FROM DUAL;

    IF v_day_number BETWEEN 2 AND 6 THEN
        IF INSERTING THEN
            RAISE_APPLICATION_ERROR(-20501, 'TABLA DE PRODUCTO PROTEGIDA');
        ELSIF DELETING THEN
            RAISE_APPLICATION_ERROR(-20500, 'TABLA DE PRODUCTO PROTEGIDA');
        END IF;
    END IF;
END TRG_PRODUCTO_BLOCK;
/

-- Trigger AFTER UPDATE OF VALOR_UNITARIO para recalcular detalles si corresponde
CREATE OR REPLACE TRIGGER TRG_PRODUCTO_RECALC
    AFTER UPDATE OF VALOR_UNITARIO ON PRODUCTO
    FOR EACH ROW
DECLARE
    v_avg_ventas  NUMBER;
BEGIN
    -- Obtener promedio de ventas del año anterior
    v_avg_ventas := PKG_LIQUIDACION.f_avg_sales_prev_year;

    -- Si el nuevo valor unitario es mayor al 10% del promedio
    IF :NEW.VALOR_UNITARIO > v_avg_ventas * 0.10 THEN
        -- Recalcular los totales en detalle_boleta para este producto
        UPDATE DETALLE_BOLETA
        SET VALOR_TOTAL = CANTIDAD * :NEW.VALOR_UNITARIO
        WHERE COD_PRODUCTO = :NEW.COD_PRODUCTO;

        -- Recalcular el monto total de cada boleta afectada
        UPDATE BOLETA
        SET MONTO_TOTAL_BOLETA = (
            SELECT SUM(VALOR_TOTAL)
            FROM DETALLE_BOLETA
            WHERE NRO_BOLETA = BOLETA.NRO_BOLETA
        )
        WHERE NRO_BOLETA IN (
            SELECT DISTINCT NRO_BOLETA
            FROM DETALLE_BOLETA
            WHERE COD_PRODUCTO = :NEW.COD_PRODUCTO
        );
    END IF;
END TRG_PRODUCTO_RECALC;
/

--=============================================================================
-- Verificaciones de TRIGGER

UPDATE INTO producto VALUES (100, 'GOLDEN NOSE', 'UN', 9999, 100, 5, 'N');

UPDATE producto
SET VALOR_UNITARIO = 1000
WHERE COD_PRODUCTO = 19;

UPDATE producto
SET VALOR_UNITARIO = 10000
WHERE COD_PRODUCTO = 19;

ROLLBACK;