--============================================================
-- Función para calcular puntaje basado en años de experiencia
CREATE OR REPLACE FUNCTION fn_ptje_annos_exp(p_numrun IN NUMBER) RETURN NUMBER IS
-- Espacio para variables de funcion
    v_min_fecha DATE;
    v_annos NUMBER;
    v_puntaje NUMBER;
BEGIN
-- Espcacio para calculos
-- Extraigo la fecha de contrato más antigua
    SELECT 
        MIN(fecha_contrato)
    INTO v_min_fecha
    FROM antecedentes_laborales
    WHERE numrun = p_numrun;
    
-- Calculo la cantidad de años de experiencia
    v_annos := TRUNC(MONTHS_BETWEEN(SYSDATE, v_min_fecha) / 12);
    
-- Calculo para el puntaje de la tabla
    SELECT 
       ptje_experiencia
    INTO v_puntaje
    FROM ptje_annos_experiencia
    WHERE v_annos BETWEEN rango_annos_ini AND rango_annos_ter;
    
    RETURN v_puntaje;  

EXCEPTION
-- Escapacio para describir excepciones en tabla
     WHEN NO_DATA_FOUND THEN
         RETURN 0;
END fn_ptje_annos_exp;
/

--==========================================================
-- Función para calcular puntaje basado a el país
CREATE OR REPLACE FUNCTION fn_ptje_pais(p_numrun IN NUMBER) RETURN NUMBER IS
-- Espacio para variables de funcion
    v_puntaje NUMBER;
    
BEGIN
--Espacio para calculos
    SELECT pp.ptje_pais
    INTO v_puntaje
    FROM ptje_pais_postula pp
    JOIN institucion i ON pp.cod_pais = i.cod_pais
    JOIN pasantia_perfeccionamiento p ON p.cod_inst = i.cod_inst
    JOIN postulacion_pasantia_perfec ppp ON ppp.cod_programa = p.cod_programa
    WHERE ppp.numrun = p_numrun;
    
    RETURN v_puntaje;
    
EXCEPTION
-- Escapacio para describir excepciones en tabla
     WHEN NO_DATA_FOUND THEN
         RETURN 0;
END fn_ptje_pais;
/


--=========================================================
-- Cabecera del package
CREATE OR REPLACE PACKAGE pkg_ptje_extra AS
    -- Espacio para variables, agregar variable pública de package
    v_pct NUMBER := 0;    
    -- Definicion nombre de la funcion, desarrollo de la funcion en body del package
    FUNCTION fn_ptje_extra(p_numrun IN NUMBER, p_pct_extra IN NUMBER) RETURN NUMBER;
    
END pkg_ptje_extra;
/

--=========================================================
-- Cuerpo del package
CREATE OR REPLACE PACKAGE BODY pkg_ptje_extra AS
    
    FUNCTION fn_ptje_extra(p_numrun IN NUMBER, p_pct_extra IN NUMBER) RETURN NUMBER IS
        v_suma_horas NUMBER;
        v_n_inst NUMBER;
        v_ptje_pais NUMBER;
        v_ptje_annos NUMBER;
        v_ptje_extra_calc NUMBER;
        
    BEGIN
        SELECT COUNT(DISTINCT establecimiento)
        INTO v_n_inst
        FROM antecedentes_laborales
        WHERE numrun = p_numrun;

        SELECT SUM(horas_semanales)
        INTO v_suma_horas
        FROM antecedentes_laborales
        WHERE numrun = p_numrun;

    IF v_n_inst > 1 AND v_suma_horas > 30 THEN
        v_ptje_pais := fn_ptje_pais(p_numrun);
        v_ptje_annos := fn_ptje_annos_exp(p_numrun);
        v_ptje_extra_calc := ROUND((v_ptje_pais + v_ptje_annos) * (p_pct_extra / 100));
    ELSE
        v_ptje_extra_calc := 0;
    END IF;
    
    RETURN v_ptje_extra_calc;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN 0;
        WHEN OTHERS THEN
            RETURN 0;
    END fn_ptje_extra;
END pkg_ptje_extra;
/



--=====================================================
-- Procedimiento principal para procesar postulantes

CREATE OR REPLACE PROCEDURE prc_procesar_postulaciones(p_porcentaje IN NUMBER) IS

    -- Cursor con todos los postulantes que tienen una postulación activa
    CURSOR c_postulantes IS
        SELECT ap.numrun,
               ap.dvrun,
               TRIM(ap.pnombre || ' ' || NVL(ap.snombre, '') || ' ' ||
                    ap.apaterno || ' ' || ap.amaterno) AS nombre_completo
          FROM ANTECEDENTES_PERSONALES ap
         WHERE ap.numrun IN (SELECT numrun FROM POSTULACION_PASANTIA_PERFEC)
         ORDER BY ap.numrun;

    v_ptje_annos_exp      NUMBER;
    v_ptje_pais           NUMBER;
    v_ptje_extra          NUMBER;
    v_run_formateado      VARCHAR2(20);
    v_mensaje_error       VARCHAR2(200);
    
BEGIN
    -- (a) Truncar tablas resultantes
    EXECUTE IMMEDIATE 'TRUNCATE TABLE DETALLE_PUNTAJE_POSTULACION';
    EXECUTE IMMEDIATE 'TRUNCATE TABLE RESULTADO_POSTULACION';
    EXECUTE IMMEDIATE 'TRUNCATE TABLE ERROR_PROCESO';

    -- Procesar cada postulante
    FOR rec IN c_postulantes LOOP
        BEGIN
           
          
            -- Calcular puntajes usando las funciones
            v_ptje_annos_exp := fn_ptje_annos_exp(rec.numrun);
            v_ptje_pais      := fn_ptje_pais(rec.numrun);
            v_ptje_extra     := pkg_ptje_extra.fn_ptje_extra(
                                    rec.numrun,
                                    p_porcentaje
                                 );

            -- Formatear run con puntos y guión (ej: 14.405.525-1)
            v_run_formateado := TRIM(TO_CHAR(rec.numrun, '999G999G999') || '-' || rec.dvrun);

            -- Insertar en tabla DETALLE_PUNTAJE_POSTULACION
            INSERT INTO DETALLE_PUNTAJE_POSTULACION (
                run_postulante,
                nombre_postulante,
                ptje_annos_exp,
                ptje_pais_postula,
                ptje_extra
            ) VALUES (
                v_run_formateado,
                rec.nombre_completo,
                v_ptje_annos_exp,
                v_ptje_pais,
                v_ptje_extra
            );

        EXCEPTION
            WHEN OTHERS THEN
                -- Registrar error y continuar con el siguiente postulante
                v_mensaje_error := 'Error al procesar postulante ' || TO_CHAR(v_run_formateado) || ': ' || SQLERRM;
                INSERT INTO ERROR_PROCESO (id_error, rutina_error, mensaje_error)
                VALUES (SEQ_ERROR.NEXTVAL, 'prc_procesar_postulaciones',
                        v_mensaje_error);
        END;
    END LOOP;

    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        v_mensaje_error := 'Error crítico en el procedimiento: ' || SQLERRM;
        INSERT INTO ERROR_PROCESO (id_error, rutina_error, mensaje_error)
        VALUES (SEQ_ERROR.NEXTVAL, 'prc_procesar_postulaciones',
                v_mensaje_error);
        RAISE;
END prc_procesar_postulaciones;
/


CREATE OR REPLACE TRIGGER trg_resultado_postulacion
    AFTER INSERT ON DETALLE_PUNTAJE_POSTULACION
    FOR EACH ROW
DECLARE
    v_ptje_final  NUMBER;
    v_resultado   VARCHAR2(20);
    v_mensaje_error VARCHAR(100);
BEGIN
    -- Calcular puntaje final (suma de los tres puntajes)
    v_ptje_final := :NEW.ptje_annos_exp + :NEW.ptje_pais_postula + :NEW.ptje_extra;

    -- Determinar resultado según regla de negocio
    IF v_ptje_final >= 2500 THEN
        v_resultado := 'SELECCIONADO';
    ELSE
        v_resultado := 'NO SELECCIONADO';
    END IF;

    -- Insertar en tabla RESULTADO_POSTULACION
    INSERT INTO RESULTADO_POSTULACION (run_postulante, ptje_final_post, resultado_post)
    VALUES (:NEW.run_postulante, v_ptje_final, v_resultado);

EXCEPTION
    WHEN OTHERS THEN
        -- Registrar error, pero no propagar para no revertir el insert en DETALLE
        v_mensaje_error := 'Error al insertar resultado para run ' || :NEW.run_postulante || ': ' || SQLERRM;
        INSERT INTO ERROR_PROCESO (id_error, rutina_error, mensaje_error)
        VALUES (SEQ_ERROR.NEXTVAL, 'trg_resultado_postulacion',
                v_mensaje_error);
        -- No se ejecuta RAISE para permitir que el detalle quede insertado
END trg_resultado_postulacion;
/

BEGIN
    prc_procesar_postulaciones(35);
END;
/