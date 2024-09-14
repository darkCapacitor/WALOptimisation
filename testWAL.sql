WITH RepaymentSchedule AS (
    -- Base case
    SELECT 
        1 AS N,
        @NextPaymentDate AS ScheduledDate,
        CAST(@BalanceAmt AS DECIMAL(18,2)) AS Balance,
        @CurrentSequence AS CurrentSeq,
        @NextInterestSequence AS NextIntSeq,
        @Sequence AS Seq
    
    UNION ALL
    
    -- Recursive case
    SELECT 
        r.N + 1,
        DATEADD(MONTH, @RepayPeriodMths, r.ScheduledDate),
        CAST(r.Balance + 
            CASE 
                WHEN @InterestAppliedToCode = '1' AND r.CurrentSeq = r.NextIntSeq
                THEN r.Balance * @EffIntRate * 90 / 36500
                ELSE 0
            END + 
            CASE 
                WHEN r.ScheduledDate < @ExpiryDate THEN @RepaymentAmt
                ELSE 0
            END AS DECIMAL(18,2)),
        r.CurrentSeq + 1,
        CASE 
            WHEN @InterestAppliedToCode = '1' AND r.CurrentSeq = r.NextIntSeq
            THEN r.NextIntSeq + 3
            ELSE r.NextIntSeq
        END,
        r.Seq + @RepayPeriodMths
    FROM RepaymentSchedule r
    WHERE r.Balance < 0 AND r.ScheduledDate <= @ExpiryDate
),

-- Adjust for working days
WorkingDayPayments AS (
    SELECT 
        r.N,
        r.Balance,
        r.CurrentSeq,
        r.NextIntSeq,
        r.Seq,
        COALESCE(
            (SELECT TOP 1 c.AsAtDate
             FROM [dbo].[syn_Model_tbl_Dim_Calendar] c
             WHERE c.RegionCode = 'UK' 
               AND c.IsWorkingDay = 1 
               AND c.[Month] = MONTH(r.ScheduledDate)
               AND c.[Year] = YEAR(r.ScheduledDate)
               AND c.AsAtDate <= @ExpiryDate
             ORDER BY c.AsAtDate DESC),
            @ExpiryDate
        ) AS PaymentDate
    FROM RepaymentSchedule r
)

-- Final result set
INSERT INTO DW.CAU_RepaymentsSchedules_TEMP (FacilityId, RepaymentAmount, PrincipalAmount, PaymentDate)
SELECT 
    @FacilityId,
    CAST(CASE
        WHEN PaymentDate = @ExpiryDate THEN ABS(Balance) + 
            CASE 
                WHEN @InterestAppliedToCode = '1' AND CurrentSeq = NextIntSeq
                THEN Balance * @EffIntRate * 90 / 36500
                ELSE 0
            END
        WHEN Balance >= 0 THEN 0
        ELSE 
            CASE
                WHEN ABS(Balance) < @RepaymentAmt THEN ABS(Balance)
                ELSE @RepaymentAmt
            END + 
            CASE 
                WHEN @InterestAppliedToCode = '1' AND CurrentSeq = NextIntSeq
                THEN Balance * @EffIntRate * 90 / 36500
                ELSE 0
            END
    END AS DECIMAL(18,2)) AS RepaymentAmount,
    CAST(CASE
        WHEN Balance >= 0 OR PaymentDate = @ExpiryDate THEN 0
        ELSE 
            CASE
                WHEN ABS(Balance) < @RepaymentAmt THEN ABS(Balance)
                ELSE @RepaymentAmt
            END
    END AS DECIMAL(18,2)) AS PrincipalAmount,
    PaymentDate
FROM WorkingDayPayments
WHERE Balance < 0 OR PaymentDate = @ExpiryDate
ORDER BY N;
