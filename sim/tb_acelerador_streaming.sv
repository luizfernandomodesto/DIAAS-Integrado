`timescale 1ns / 1ps

// Manda várias amostras pro hardware, uma atrás da outra, numa simulação
// só - o buffer circular guarda o histórico entre elas, sem reiniciar.
module tb_acelerador_streaming;

    localparam int NUMTAPS = 127;
    localparam int TAXA_BAUD_SIM = 16_000_000; // so da simulacao, acelera o teste
    localparam int TEMPO_BIT     = (50_000_000 / TAXA_BAUD_SIM) * 20;

    logic clk;
    logic rst_n;
    logic rx;
    logic tx;

    acelerador_streaming_top #(
        .TAXA_BAUD(TAXA_BAUD_SIM),
        .NUMTAPS(NUMTAPS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .rx(rx),
        .tx(tx)
    );

    always #10 clk = ~clk; // clock de 50MHz

    // Manda 1 byte pela UART simulada (bit de start, 8 bits, bit de stop)
    task envia_byte_serial(input logic [7:0] dado);
        begin
            rx = 1'b0;
            #(TEMPO_BIT);
            for (int b = 0; b < 8; b++) begin
                rx = dado[b];
                #(TEMPO_BIT);
            end
            rx = 1'b1;
            #(TEMPO_BIT);
        end
    endtask

    // Manda uma palavra de 32 bits, um byte de cada vez
    task envia_palavra_serial(input logic [31:0] palavra);
        begin
            envia_byte_serial(palavra[31:24]);
            envia_byte_serial(palavra[23:16]);
            envia_byte_serial(palavra[15:8]);
            envia_byte_serial(palavra[7:0]);
        end
    endtask

    integer fd_entrada, fd_saida;
    integer status;
    logic [31:0] amostra;
    integer total_amostras;
    integer fd;

    string caminho_amostras;
    string caminho_saida;

    initial begin
        // Le os dois argumentos: arquivo de entrada e onde escrever a saida
        if (!$value$plusargs("AMOSTRAS=%s", caminho_amostras)) begin
            $display("ERRO: use +AMOSTRAS=arquivo.hex");
            $finish;
        end
        if (!$value$plusargs("SAIDA=%s", caminho_saida)) begin
            $display("ERRO: use +SAIDA=arquivo.txt");
            $finish;
        end

        // Reseta o hardware antes de comecar
        clk   = 0;
        rst_n = 0;
        rx    = 1;
        #100;
        rst_n = 1;
        #100;

        fd_entrada = $fopen(caminho_amostras, "r");
        if (fd_entrada == 0) begin
            $display("ERRO: nao consegui abrir %s", caminho_amostras);
            $finish;
        end
        fd_saida = $fopen(caminho_saida, "w");
        if (fd_saida == 0) begin
            $display("ERRO: nao consegui abrir %s para escrita", caminho_saida);
            $finish;
        end

        // Le uma amostra por linha, manda pro hardware, espera o resultado
        total_amostras = 0;
        while ($fscanf(fd_entrada, "%h\n", amostra) == 1) begin
            envia_palavra_serial(amostra);

            // Espera o calculo terminar, com um teto de seguranca caso trave
            fork
                begin : espera_normal
                    @(posedge dut.fsm_inst.resultado_pronto);
                    repeat (3) @(posedge clk);
                end
                begin : espera_timeout
                    repeat (NUMTAPS + 50) @(posedge clk);
                    $display("ERRO: timeout esperando resultado_pronto (amostra %0d)", total_amostras);
                    $finish;
                end
            join_any
            disable fork;

            $fwrite(fd_saida, "%0d\n", $signed(dut.fio_acumulador));
            total_amostras = total_amostras + 1;
        end

        $fclose(fd_entrada);
        $fclose(fd_saida);
        $display("OK: %0d amostras processadas, resultados em %s", total_amostras, caminho_saida);
        $finish;
    end

endmodule
